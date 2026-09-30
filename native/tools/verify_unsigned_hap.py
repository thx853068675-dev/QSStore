"""Fail closed if an unsigned release contains an outer or embedded HAP signature."""

import argparse
from io import BytesIO
from pathlib import Path
import struct
import zipfile


def inspect_unsigned(data, label, depth=0):
    if depth > 8:
        raise ValueError('Embedded HAP nesting exceeds 8 levels')
    with zipfile.ZipFile(BytesIO(data)) as archive:
        entries = archive.infolist()
        if not entries or len({item.filename for item in entries}) != len(entries):
            raise ValueError(f'{label}: empty archive or duplicate entries')
        last = max(entries, key=lambda item: item.header_offset)
        start = last.header_offset
        if data[start:start + 4] != b'PK\x03\x04':
            raise ValueError(f'{label}: invalid local ZIP header')
        name_size, extra_size = struct.unpack_from('<HH', data, start + 26)
        end = start + 30 + name_size + extra_size + last.compress_size
        if last.flag_bits & 8:
            end += 16 if data[end:end + 4] == b'PK\x07\x08' else 12
        # Official HAP signatures sit between the last ZIP entry and directory.
        # Refuse every gap, including an unknown future signing block format.
        if end != archive.start_dir:
            raise ValueError(f'{label}: signature block or unexplained bytes before ZIP directory')
        for item in entries:
            name = item.filename.lower()
            if name.startswith('meta-inf/') and name.endswith(('.sf', '.rsa', '.dsa', '.ec')):
                raise ValueError(f'{label}: signature entry {item.filename}')
        checked = [label]
        for item in entries:
            if item.filename.lower().endswith(('.hap', '.hsp', '.app')):
                if item.file_size > 512 * 1024 * 1024:
                    raise ValueError(f'{label}: embedded package exceeds size limit')
                checked.extend(inspect_unsigned(archive.read(item),
                    f'{label}!/{item.filename}', depth + 1))
        return checked


def verify_unsigned(path):
    path = Path(path)
    return inspect_unsigned(path.read_bytes(), path.name)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('hap', type=Path)
    args = parser.parse_args()
    for name in verify_unsigned(args.hap):
        print('Unsigned:', name)
