"""Fail a release if protection is disabled, incomplete or leaks private maps.

This checks the compiler's actual name mapping and ELF symbols, not just flags.
Keep the mapping beside the local artifact for crash diagnosis, never in the HAP.
"""
import hashlib
import json
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


def verify_release(hap, entry):
    hap, entry = Path(hap), Path(entry)
    cache = json.loads((entry / 'obfuscation-namecache.json').read_text())
    core = {}
    for filename in CORE_FILES:
        original = 'entry/src/main/ets/' + filename + '.ets'
        mapping = cache.get(original, {})
        renamed = mapping.get('obfName', '')
        if not renamed or renamed == original:
            raise ValueError('Release core is not obfuscated: ' + original)
        methods = mapping.get('MemberMethodCache', {})
        if not any(key.split(':')[0] != value for key, value in methods.items()):
            raise ValueError('Release core methods are not obfuscated: ' + original)
        core[filename] = renamed
    # Old login, identity, jobs, cache and API JSON must retain their schema.
    contracts = (entry / 'obfuscation-contracts.txt').read_text().split('-keep-property-name\n', 1)[1]
    properties = {line for line in contracts.split('-keep-global-name', 1)[0].splitlines()
                  if line and not line.startswith('#')}
    changed_contracts = properties.intersection(cache.get('PropertyCache', {}))
    if changed_contracts:
        raise ValueError('Serialized contract was renamed: ' + ', '.join(sorted(changed_contracts)))
    with zipfile.ZipFile(hap) as archive:
        leaked = [name for name in archive.namelist() if
                  name.lower().endswith(('.map', '.ets', '.ts', '.rs', '.cpp', '.c', '.h')) or
                  any(marker in name.lower() for marker in ('sourcemap', 'namecache', 'kept-names', 'obfuscation-'))]
        if leaked:
            raise ValueError('Release exposes source/diagnostic maps: ' + ', '.join(leaked))
        exports = elf_symbols(archive.read('libs/arm64-v8a/libhap_core.so'))
        if exports != ['RegisterHapCore']:
            raise ValueError('Unexpected native exports: ' + ', '.join(exports))
    return {'sha256': hashlib.sha256(hap.read_bytes()).hexdigest(), 'bytes': hap.stat().st_size,
            'protectedCoreFiles': core, 'renamedProperties': len(cache['PropertyCache']),
            'renamedFileSegments': len(cache['FileNameCache']), 'nativeExports': exports,
            'stableContractFields': len(properties), 'sourceOrMapsPackaged': False}
