import importlib.util
from io import BytesIO
from pathlib import Path
import struct
import unittest
import zipfile

spec = importlib.util.spec_from_file_location('unsigned', Path(__file__).parents[1] / 'tools/verify_unsigned_hap.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def package(entries):
    output = BytesIO()
    with zipfile.ZipFile(output, 'w') as z:
        for name, data in entries:
            z.writestr(name, data)
    return output.getvalue()


def with_signature(data):
    footer = data.rfind(b'PK\x05\x06')
    directory = struct.unpack_from('<I', data, footer + 16)[0]
    block = b'pretend HAP signing block' * 2
    result = bytearray(data[:directory] + block + data[directory:])
    struct.pack_into('<I', result, footer + len(block) + 16, directory + len(block))
    return bytes(result)


class UnsignedArtifactTests(unittest.TestCase):
    def test_unsigned_outer_and_worker(self):
        worker = package([('module.json', b'{}')])
        outer = package([('module.json', b'{}'), ('resources/rawfile/worker.hap', worker)])
        self.assertEqual(len(module.inspect_unsigned(outer, 'outer.hap')), 2)

    def test_unsigned_outer_does_not_hide_signed_worker(self):
        worker = with_signature(package([('module.json', b'{}')]))
        outer = package([('module.json', b'{}'), ('resources/rawfile/worker.hap', worker)])
        with self.assertRaisesRegex(ValueError, 'worker.hap'):
            module.inspect_unsigned(outer, 'outer.hap')

    def test_signature_block_of_unknown_format_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'signature block'):
            module.inspect_unsigned(with_signature(package([('module.json', b'{}')])), 'outer.hap')


if __name__ == '__main__':
    unittest.main()
