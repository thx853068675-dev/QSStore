"""Bounded APP/ZIP inspection. Extracted paths are generated, never archive names."""
from __future__ import annotations
import copy
import json
import os
import re
import tempfile
import zipfile
from urllib.parse import quote, unquote, urldefrag
from . import collector, artifact_cache

MAX_TOTAL = 2 * 1024 * 1024 * 1024
MAX_PACKAGES = 32
SELECTOR = 'qingqi-package='


def package_entries(archive):
    rows, names, total = [], set(), 0
    for item in archive.infolist():
        if not item.filename.lower().endswith(('.hap', '.app')):
            continue
        name = item.filename
        if (not name or len(name) > 1024 or name.startswith('/') or any(c in name for c in ('\\', '\0', ':'))
                or any(p in ('', '.', '..') for p in name.split('/'))):
            raise collector.CollectError('压缩包包含不安全的安装包路径')
        total += item.file_size
        if (name in names or item.flag_bits & 1 or item.is_dir() or item.file_size <= 0
                or item.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED)
                or item.compress_size <= 0 or item.file_size // item.compress_size > 200
                or total > MAX_TOTAL or len(rows) >= MAX_PACKAGES):
            raise collector.CollectError('压缩包包含重复、加密或超限的安装包')
        names.add(name)
        rows.append(item)
    return rows


def extract(archive, item, path):
    with archive.open(item) as src, open(path, 'wb') as dst:
        copied = 0
        while True:
            data = src.read(1024 * 1024)
            if not data:
                break
            copied += len(data)
            if copied > item.file_size:
                raise collector.CollectError('安装包解压长度超限')
            dst.write(data)
        if copied != item.file_size:
            raise collector.CollectError('安装包解压不完整')


def inspect_hap(path):
    with zipfile.ZipFile(path) as archive:
        collector.validate_hap_manifests(archive)
        if 'module.json' not in archive.namelist():
            raise collector.CollectError('安装包缺少 module.json')
        module = json.loads(archive.read('module.json'))
    meta = collector.parse_hap_metadata(path)
    if (not re.fullmatch(r'[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+', meta['bundle_name'])
            or meta['version_code'] <= 0 or not (module.get('module') or {}).get('name')):
        raise collector.CollectError('安装包应用身份或模块无效')
    meta['_module_name'] = module['module']['name']
    meta['_entry'] = module['module'].get('type') == 'entry' or (not module['module'].get('type') and bool(module['module'].get('mainElement')))
    icon = collector.extract_hap_icon(path)
    if icon:
        meta['_icon'] = icon
    meta['_icon_checked'] = True
    return meta


def inspect_app(path):
    with tempfile.TemporaryDirectory(prefix='hapstore-app-') as temp, zipfile.ZipFile(path) as archive:
        entries = package_entries(archive)
        if not entries or any(not row.filename.lower().endswith('.hap') for row in entries):
            raise collector.CollectError('APP 内没有有效的 HAP 模块')
        modules = []
        for index, item in enumerate(entries):
            staged = os.path.join(temp, f'module-{index}.hap')
            extract(archive, item, staged)
            modules.append(inspect_hap(staged))
        primary = next((m for m in modules if m['_entry']), modules[0])
        if (len({m['_module_name'] for m in modules}) != len(modules) or any(
                (m['bundle_name'], m['version_code']) != (primary['bundle_name'], primary['version_code']) for m in modules)):
            raise collector.CollectError('APP 模块的应用身份、版本或模块名不一致')
        return primary


def _present_metadata(asset, url, selected, rows):
    result = []
    for metadata in rows:
        entry = metadata.get('archive_entry', '')
        if selected and entry != selected:
            continue
        if entry:
            result.append(dict(asset, **{k: v for k, v in metadata.items() if k not in ('name', 'download_url', 'size', 'sha256')}, name=asset['name'] if selected else asset['name'] + ' / ' + entry,
                download_url=url + '#' + SELECTOR + quote(entry, safe='')))
        else:
            result.append(dict(asset, **metadata))
    if not result:
        raise collector.CollectError('ZIP 中已不存在所选安装包，请重新检查')
    return result


def scan_asset(asset, token=''):
    """Return validated virtual attachments; all retain the upstream ZIP digest."""
    url, fragment = urldefrag(asset['download_url'])
    selected = unquote(fragment[len(SELECTOR):]) if fragment.startswith(SELECTOR) else ''
    kind = 'zip' if url.lower().endswith('.zip') or selected else 'app'
    cached = artifact_cache.get(asset.get('sha256', ''), kind)
    if cached is not None:
        return _present_metadata(asset, url, selected, cached)
    source = collector._download_to_temp(url, token=token)
    if not source:
        raise collector.CollectError('安装包暂时无法下载，后台检查将重试')
    try:
        digest = collector._sha256_file(source)
        if asset.get('sha256') and digest != asset['sha256']:
            raise collector.CollectError('安装包与 GitHub 摘要不一致')
        if not asset.get('sha256'):
            raise collector.CollectError('GitHub 尚未提供该安装包的 SHA-256 摘要')
        is_zip = url.lower().endswith('.zip') or bool(selected)
        if not is_zip:
            meta = inspect_app(source) if asset['name'].lower().endswith('.app') else inspect_hap(source)
            artifact_cache.put(digest, kind, [meta])
            return [dict(asset, **meta)]
        result = []
        with tempfile.TemporaryDirectory(prefix='hapstore-zip-') as temp, zipfile.ZipFile(source) as archive:
            entries = package_entries(archive)
            for index, item in enumerate(entries):
                staged = os.path.join(temp, f'package-{index}')
                extract(archive, item, staged)
                try:
                    meta = inspect_app(staged) if item.filename.lower().endswith('.app') else inspect_hap(staged)
                except (collector.CollectError, zipfile.BadZipFile, ValueError, KeyError):
                    continue
                result.append(dict(asset, **meta,
                    name=asset['name'] if selected else asset['name'] + ' / ' + item.filename,
                    download_url=url + '#' + SELECTOR + quote(item.filename, safe=''),
                    archive_entry=item.filename))
        if not result:
            raise collector.CollectError('ZIP 内没有可安装的 APP 或 HAP（已检查清单）')
        artifact_cache.put(digest, kind, result)
        return _present_metadata(asset, url, selected, result)
    except (zipfile.BadZipFile, RuntimeError, ValueError, KeyError) as error:
        raise collector.CollectError(f'无法解析安装包：{error}') from error
    finally:
        collector._unlink_quiet(source)


def inspect_snapshot(snapshot, token=''):
    result = copy.deepcopy(snapshot)
    # Only the first release with installable attachments is offered for listing.
    release = next((r for r in result['releases'] if r.get('assets')), None)
    if release is None:
        raise collector.CollectError('Release 中没有安装包')
    choices, failures = [], []
    for asset in release['assets']:
        if asset['name'].lower().endswith(('.app', '.zip')):
            try:
                choices.extend(scan_asset(asset, token))
            except collector.CollectError as error:
                failures.append(f"{asset['name']}: {error}")
        else:
            choices.append(asset)
    if not choices:
        raise collector.CollectError('没有有效安装包：' + '; '.join(failures))
    release['assets'] = choices
    return result
