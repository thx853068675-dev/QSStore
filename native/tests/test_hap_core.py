"""Host tests for the bounded HAP ZIP reader; requires a C++17 compiler and zlib."""

import json
import pathlib
import random
import struct
import subprocess
import tempfile
import unittest
import warnings
import zipfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
CORE = ROOT / "entry/src/main/cpp/hap_core"


class HapReaderTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.dir = pathlib.Path(cls.temp.name)
        cls.cli = cls.dir / "hap_inspect"
        subprocess.run([
            "c++", "-std=c++17", "-Wall", "-Wextra", "-Werror", "-I", str(CORE),
            str(CORE / "zip_reader.cpp"), str(ROOT / "tests/hap_inspect_cli.cpp"),
            str(CORE / "signing_block.cpp"),
            "-lz", "-o", str(cls.cli),
        ], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def run_reader(self, file, entry="module"):
        args = [str(self.cli), str(file)]
        if entry in ("pack", "block"):
            args.append(entry)
        return subprocess.run(args, capture_output=True, text=True)

    def create_hap(self, name, manifest, method=zipfile.ZIP_DEFLATED):
        path = self.dir / name
        with zipfile.ZipFile(path, "w", method) as archive:
            archive.writestr("module.json", manifest)
            archive.writestr("large/other.bin", b"A" * 10000)
        return path

    def add_structural_signing_block(self, source, name):
        # This fixture has valid block framing, but deliberately no real
        # cryptographic signature. inspectSigningBlock must never imply trust.
        raw = source.read_bytes()
        with zipfile.ZipFile(source) as archive:
            central = archive.start_dir
        eocd = raw.rfind(b"PK\x05\x06")
        self.assertGreater(eocd, central)
        data = b"fake-sign"
        entries = struct.pack("<III", 0x20000000, len(data), 12)
        block_size = len(entries) + len(data) + 32
        block = entries + data + struct.pack(
            "<IQQQI", 1, block_size, 0x676973207061683C,
            0x3E6B636F6C62206E, 3)
        footer = bytearray(raw[eocd:])
        struct.pack_into("<I", footer, 16, central + block_size)
        path = self.dir / name
        path.write_bytes(raw[:central] + block + raw[central:eocd] + footer)
        return path

    def test_stored_and_deflated_manifest(self):
        content = json.dumps({"app": {"bundleName": "com.example.test"}},
                             ensure_ascii=False)
        for method in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
            with self.subTest(method=method):
                path = self.create_hap(f"valid-{method}.hap", content, method)
                result = self.run_reader(path)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, content)

    def test_corrupt_manifest_is_rejected(self):
        path = self.create_hap("corrupt.hap", '{"app":{}}', zipfile.ZIP_STORED)
        raw = bytearray(path.read_bytes())
        with zipfile.ZipFile(path) as archive:
            info = archive.getinfo("module.json")
            offset = info.header_offset
        name_len, extra_len = struct.unpack_from("<HH", raw, offset + 26)
        raw[offset + 30 + name_len + extra_len] ^= 1
        path.write_bytes(raw)
        self.assertNotEqual(self.run_reader(path).returncode, 0)

    def test_missing_and_truncated_manifest_are_rejected(self):
        path = self.dir / "missing.hap"
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("other.json", "{}")
        self.assertNotEqual(self.run_reader(path).returncode, 0)
        path.write_bytes(path.read_bytes()[:-10])
        self.assertNotEqual(self.run_reader(path).returncode, 0)

    def test_manifest_size_limit_is_enforced(self):
        path = self.create_hap("oversize.hap", "A" * (4 * 1024 * 1024 + 1))
        self.assertNotEqual(self.run_reader(path).returncode, 0)

    def test_duplicate_manifest_is_rejected(self):
        path = self.dir / "duplicate.hap"
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("module.json", "{}")
                archive.writestr("module.json", '{"app":{}}')
        self.assertNotEqual(self.run_reader(path).returncode, 0)

    def run_icon(self, file, icon_name):
        return subprocess.run(
            [str(self.cli), str(file), "icon", icon_name],
            capture_output=True,
        )

    def test_icon_is_found_through_the_module_json_reference(self):
        # 设备上的真实布局：module.json 里是 $media:app_icon，文件在同名 path 下
        payload = b"\x89PNG\r\n\x1a\n" + b"icon-body" * 8
        path = self.create_hap("icon.hap", json.dumps({
            "app": {"bundleName": "com.example.app", "icon": "$media:app_icon"},
            "module": {"name": "entry"},
        }))
        with zipfile.ZipFile(path, "a") as archive:
            archive.writestr("resources/base/media/app_icon.png", payload)
        result = self.run_icon(path, "$media:app_icon")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, payload)

    def test_icon_survives_a_density_specific_directory(self):
        payload = b"\x89PNG\r\n\x1a\n" + b"dense" * 4
        path = self.create_hap("icon-density.hap", json.dumps({
            "app": {"bundleName": "com.example.app", "icon": "$media:app_icon"},
            "module": {"name": "entry"},
        }))
        with zipfile.ZipFile(path, "a") as archive:
            archive.writestr("resources/base/media/app_icon@3x.png", payload)
        result = self.run_icon(path, "$media:app_icon")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, payload)

    def test_missing_icon_is_empty_not_an_error(self):
        # 没有图标是正常情况，调用方要能区分「没有」和「读失败」
        path = self.create_hap("no-icon.hap", '{"app":{"icon":"$media:app_icon"}}')
        result = self.run_icon(path, "$media:app_icon")
        self.assertEqual((result.returncode, result.stdout), (0, b""))

    def test_icon_size_limit_is_enforced(self):
        path = self.create_hap("big-icon.hap", '{"app":{"icon":"$media:app_icon"}}')
        with zipfile.ZipFile(path, "a") as archive:
            archive.writestr("resources/base/media/app_icon.png",
                             b"\x89PNG\r\n\x1a\n" + b"B" * (1024 * 1024))
        result = self.run_icon(path, "$media:app_icon")
        self.assertEqual((result.returncode, result.stdout), (0, b""))

    def test_icon_name_cannot_escape_the_media_directory(self):
        # 清单里的名字只当查找键用，不能变成任意路径读取
        path = self.create_hap("escape.hap", '{"app":{"icon":"../../etc/passwd"}}')
        with zipfile.ZipFile(path, "a") as archive:
            archive.writestr("etc/passwd", b"root:x:0:0")
            archive.writestr("resources/base/media/passwd", b"not-the-real-one")
        result = self.run_icon(path, "../../etc/passwd")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotEqual(result.stdout, b"root:x:0:0")

    def test_optional_pack_info_and_duplicate_rejection(self):
        path = self.create_hap("no-pack.hap", '{"app":{}}')
        result = self.run_reader(path, "pack")
        self.assertEqual((result.returncode, result.stdout), (0, ""))
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(path, "a") as archive:
                archive.writestr("pack.info", '{"summary":{}}')
                archive.writestr("pack.info", '{"summary":{}}')
        self.assertNotEqual(self.run_reader(path, "pack").returncode, 0)

    def test_pack_info_from_real_signed_hap(self):
        samples = list((ROOT.parent / "dist").glob("*-signed.hap"))
        if not samples:
            self.skipTest("No signed HAP fixture available")
        result = self.run_reader(samples[0], "pack")
        self.assertEqual(result.returncode, 0, result.stderr)
        pack = json.loads(result.stdout)
        self.assertGreater(pack["summary"]["app"]["version"]["code"], 0)

    def test_signing_block_rejects_unsigned_hap(self):
        path = self.create_hap("unsigned.hap", '{"app":{}}')
        self.assertNotEqual(self.run_reader(path, "block").returncode, 0)

    def test_structural_signing_block_and_corruption(self):
        unsigned = self.create_hap("block-source.hap", '{"app":{}}')
        path = self.add_structural_signing_block(unsigned, "framed.hap")
        result = self.run_reader(path, "block")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.split(",")[:2], ["3", "1"])
        raw = bytearray(path.read_bytes())
        with zipfile.ZipFile(path) as archive:
            central = archive.start_dir
        block_size = struct.unpack_from("<Q", raw, central - 28)[0]
        raw[central - block_size + 8] = 0xff  # Subblock offset must be contiguous.
        broken = self.dir / "bad-offset.hap"
        broken.write_bytes(raw)
        self.assertNotEqual(self.run_reader(broken, "block").returncode, 0)

    def test_signing_block_from_real_signed_hap(self):
        samples = [pathlib.Path("/tmp/qingqi-native-preview-sign/qingqi-native-preview-signed.hap")]
        samples += list((ROOT.parent / "dist").glob("*-signed.hap"))
        samples = [sample for sample in samples if sample.exists()]
        if not samples:
            self.skipTest("No signed HAP fixture available")
        result = self.run_reader(samples[0], "block")
        self.assertEqual(result.returncode, 0, result.stderr)
        version, count, offset, size = map(int, result.stdout.split(","))
        self.assertIn(version, (2, 3))
        self.assertGreater(count, 0)
        self.assertGreater(offset, 0)
        self.assertGreater(size, 32)

    def test_signing_block_rejects_tampered_header(self):
        sample = pathlib.Path("/tmp/qingqi-native-preview-sign/qingqi-native-preview-signed.hap")
        if not sample.exists():
            self.skipTest("No signed HAP fixture available")
        raw = bytearray(sample.read_bytes())
        with zipfile.ZipFile(sample) as archive:
            central = archive.start_dir
        raw[central - 16] ^= 1  # Magic bytes immediately before the directory.
        path = self.dir / "bad-signing-block.hap"
        path.write_bytes(raw)
        self.assertNotEqual(self.run_reader(path, "block").returncode, 0)

    def test_mutated_zip_headers_never_crash(self):
        source = self.create_hap("mutation-source.hap", '{"app":{}}')
        original = source.read_bytes()
        rng = random.Random(217)
        for i in range(30):
            raw = bytearray(original)
            for _ in range(1 + i % 4):
                position = rng.randrange(len(raw))
                raw[position] ^= 1 << rng.randrange(8)
            path = self.dir / f"mutation-{i}.hap"
            path.write_bytes(raw)
            result = self.run_reader(path)
            self.assertIn(result.returncode, (0, 1), result.stderr)


if __name__ == "__main__":
    unittest.main()
