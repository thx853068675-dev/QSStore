#!/usr/bin/env python3
# Copyright QuietStart contributors. SPDX-License-Identifier: MIT
"""元数据导出 / 导入。

用途有两个，都是生产必需的：

1) **离线播种**：服务器出站被彻底拦截（实测连 gh-proxy 等镜像也不可达），
   无法自行采集。于是采集在能出网的环境完成后，导出为 JSON 再导入生产库。

2) **备份 / 迁移**：把索引（应用、release、asset 元信息）导出成可读文件。
   注意这里**不含任何 HAP 文件本体** —— 服务端从来不存包。
"""

from __future__ import annotations

import json
import base64
import sys
import time
from typing import Any

from . import db

EXPORT_VERSION = 2


def export_all() -> dict[str, Any]:
    """导出全部应用与其 release/asset 元信息。"""
    c = db.connect()
    apps = []
    rows = c.execute("SELECT * FROM app ORDER BY id").fetchall()
    for row in rows:
        app = dict(row)
        rels = []
        rrows = c.execute(
            "SELECT * FROM release WHERE app_id=? ORDER BY published_at DESC",
            (row["id"],),
        ).fetchall()
        for r in rrows:
            arows = c.execute(
                "SELECT * FROM asset WHERE release_id=? ORDER BY name", (r["id"],)
            ).fetchall()
            rels.append({
                "tag": r["tag"],
                "name": r["name"],
                "body": r["body"],
                "published_at": r["published_at"],
                "prerelease": bool(r["prerelease"]),
                "html_url": r["html_url"],
                "etag": r["etag"],
                "github_downloads": r["github_downloads"],
                "assets": [
                    {
                        "name": a["name"],
                        "size": a["size"],
                        "sha256": a["sha256"],
                        "download_url": a["download_url"],
                        "bundle_name": a["bundle_name"],
                        "version_code": a["version_code"],
                        "version_name": a["version_name"],
                        "min_api": a["min_api"],
                    }
                    for a in arows
                ],
            })
        apps.append({
            "repo_full_name": app["repo_full_name"],
            "display_name": app["display_name"],
            "summary": app["summary"],
            "description": app["description"],
            "icon_url": app["icon_url"],
            "category": app["category"],
            "tags_json": app["tags_json"],
            "stars": app["stars"],
            "license": app["license"],
            "homepage": app["homepage"],
            "verified": app["verified"],
            "status": app["status"],
            "featured": app["featured"],
            "icon": (lambda icon: {"mime": icon[0], "data": base64.b64encode(icon[1]).decode("ascii")}
                     if icon else None)(db.app_icon(app["id"])),
            "releases": rels,
        })
    return {
        "export_version": EXPORT_VERSION,
        "exported_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "apps": apps,
    }


def import_all(payload: dict[str, Any], *, replace_releases: bool = True,
               progress=lambda s: None) -> dict[str, Any]:
    """导入导出文件。幂等：重复导入同一份不会产生重复数据。"""
    if payload.get("export_version") not in (1, EXPORT_VERSION):
        raise ValueError(
            f"导出文件版本不匹配：期望 {EXPORT_VERSION}，"
            f"实际 {payload.get('export_version')}"
        )

    db.init_db()
    n_apps = 0
    n_rels = 0
    n_assets = 0

    for app in payload.get("apps", []):
        repo = app.get("repo_full_name")
        if not repo:
            continue
        fields = {
            k: app[k]
            for k in (
                "display_name", "summary", "description", "icon_url", "category",
                "tags_json", "stars", "license", "homepage", "verified", "status",
                "featured",
            )
            if k in app
        }
        fields["synced_at"] = int(time.time())
        app_id = db.upsert_app(repo, **fields)
        icon = app.get("icon")
        if isinstance(icon, dict) and icon.get("data"):
            db.put_app_icon(app_id, icon["mime"], base64.b64decode(icon["data"], validate=True))
        n_apps += 1

        releases = app.get("releases") or []
        if releases and replace_releases:
            db.replace_releases(
                app_id,
                [
                    {
                        "tag": r.get("tag", ""),
                        "name": r.get("name", ""),
                        "body": r.get("body", ""),
                        "published_at": r.get("published_at", ""),
                        "prerelease": r.get("prerelease", False),
                        "html_url": r.get("html_url", ""),
                        "etag": r.get("etag", ""),
                        "github_downloads": r.get("github_downloads"),
                        "assets": [
                            {
                                "name": a.get("name", ""),
                                "size": a.get("size", 0),
                                "sha256": a.get("sha256", ""),
                                "download_url": a.get("download_url", ""),
                                "bundle_name": a.get("bundle_name", ""),
                                "version_code": a.get("version_code", 0),
                                "version_name": a.get("version_name", ""),
                                "min_api": a.get("min_api", 0),
                            }
                            for a in (r.get("assets") or [])
                        ],
                    }
                    for r in releases
                ],
            )
            n_rels += len(releases)
            n_assets += sum(len(r.get("assets") or []) for r in releases)
        progress(f"  导入 {repo}: {len(releases)} 个 release")

    db.set_meta("last_import", time.strftime("%Y-%m-%dT%H:%M:%S"))
    return {"apps": n_apps, "releases": n_rels, "assets": n_assets}


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("用法: python3 -m hapstore.transfer export <out.json>")
        print("      python3 -m hapstore.transfer import <in.json>")
        return 64

    cmd = argv[1]
    if cmd == "export":
        out = argv[2] if len(argv) > 2 else "hapstore-export.json"
        db.init_db()
        payload = export_all()
        with open(out, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False, indent=2)
        n = len(payload["apps"])
        r = sum(len(a["releases"]) for a in payload["apps"])
        print(f"已导出 {n} 个应用 / {r} 个 release → {out}")
        return 0

    if cmd == "import":
        if len(argv) < 3:
            print("缺少输入文件")
            return 64
        with open(argv[2], encoding="utf-8") as f:
            payload = json.load(f)
        result = import_all(payload, progress=print)
        print(f"导入完成：{result}")
        return 0

    print(f"未知命令：{cmd}")
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv))
