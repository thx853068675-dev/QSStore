"""Verify a normal, unobfuscated release without packaging source or private diagnostics."""
import hashlib
from pathlib import Path
import struct
import zipfile


CORE_FILES = ('data/SigningIdentity', 'data/AgcProfile', 'jobs/NativeJobRuntime',
              'jobs/InstallCoordinator')


def elf_symbols(data):
    if data[:6] != b'\x7fELF\x02\x01':
        raise ValueError('Native release is not little-endian ELF64')
    offset = struct.unpack_from('<Q', data, 40)[0]
    size, count, names_index = struct.unpack_from('<HHH', data, 58)
    sections = [struct.unpack_from('<IIQQQQIIQQ', data, offset + i * size) for i in range(count)]
    names = sections[names_index]
    strings = data[names[4]:names[4] + names[5]]

    def string_at(blob, start):
        return blob[start:blob.index(0, start)].decode('utf8', errors='replace')

    labels = {string_at(strings, section[0]): section for section in sections}
    if '.symtab' in labels or any(name.startswith('.debug') or name == '.zdebug_info' for name in labels):
        raise ValueError('Native release still contains debug symbols')
    dynamic = labels['.dynsym']
    table = sections[dynamic[6]]
    symbol_strings = data[table[4]:table[4] + table[5]]
    exports = []
    for start in range(dynamic[4], dynamic[4] + dynamic[5], dynamic[9]):
        name, info, visibility, index, _, _ = struct.unpack_from('<IBBHQQ', data, start)
        if index and info >> 4 in (1, 2) and visibility & 3 in (0, 3):
            exports.append(string_at(symbol_strings, name))
    return exports


def verify_release(hap):
    hap = Path(hap)
    with zipfile.ZipFile(hap) as archive:
        leaked = [name for name in archive.namelist() if
                  name.lower().endswith(('.map', '.ets', '.ts', '.rs', '.cpp', '.c', '.h')) or
                  any(marker in name.lower() for marker in ('sourcemap', 'namecache', 'kept-names', 'obfuscation-'))]
        if leaked:
            raise ValueError('Release exposes source/diagnostic maps: ' + ', '.join(leaked))
        bytecode = archive.read('ets/modules.abc')
        if any(name.rsplit('/', 1)[1].encode() not in bytecode for name in CORE_FILES):
            raise ValueError('Release unexpectedly renamed core implementation symbols')
        exports = elf_symbols(archive.read('libs/arm64-v8a/libhap_core.so'))
        if exports != ['RegisterHapCore']:
            raise ValueError('Unexpected native exports: ' + ', '.join(exports))
    return {'sha256': hashlib.sha256(hap.read_bytes()).hexdigest(), 'bytes': hap.stat().st_size,
            'obfuscated': False, 'nativeExports': exports, 'sourceOrMapsPackaged': False}
