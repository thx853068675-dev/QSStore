#!/usr/bin/env python3
"""Run the same host regression gate locally and in CI; publishing is never part of this command."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
SDK_TS = Path('/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--offline', action='store_true', help='Use only already cached Rust dependencies')
    parser.add_argument('--build', action='store_true', help='Also build and recursively verify an unsigned formal HAP (DevEco required)')
    parser.add_argument('--output', type=Path, help='Directory for logs, summary and optional unsigned HAP')
    args = parser.parse_args()
    output = args.output or Path(tempfile.mkdtemp(prefix='qingqi-check-'))
    output = output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    env['PYTHONPATH'] = str(ROOT / 'server') + os.pathsep + str(ROOT) + os.pathsep + env.get('PYTHONPATH', '')
    if 'QINGQI_TYPESCRIPT' not in env:
        if SDK_TS.exists():
            env['QINGQI_TYPESCRIPT'] = str(SDK_TS)
        else:
            env['QINGQI_TYPESCRIPT'] = subprocess.check_output(
                ['node', '-p', 'require.resolve("typescript")'], cwd=ROOT, text=True).strip()
    cargo = shutil.which('cargo')
    if not cargo:
        candidate = Path('/opt/homebrew/opt/rustup/bin/cargo')
        if candidate.exists():
            cargo = str(candidate)
    if not cargo:
        raise SystemExit('Rust cargo is required; install the project toolchain first')
    env['PATH'] = str(Path(cargo).parent) + os.pathsep + env.get('PATH', '')
    rust_args = ['--lib', '--locked'] + (['--offline'] if args.offline else [])
    steps = [
        ('client', ['node', '--test', *map(str, sorted((ROOT / 'native/tests').glob('test_*.cjs')))], 120),
        ('server', [sys.executable, '-m', 'unittest', 'discover', '-s', 'server/tests'], 120),
        ('hap-core', [sys.executable, 'native/tests/test_hap_core.py'], 120),
        ('unsigned-artifact', [sys.executable, 'native/tests/test_unsigned_artifact.py'], 60),
        ('signer', [cargo, 'test', '--manifest-path', 'native/rust_signer/Cargo.toml', *rust_args], 900),
        ('hdc', [cargo, 'test', '--manifest-path', 'native/hdc_transport/hdc/Cargo.toml', *rust_args], 900),
    ]
    if args.build:
        version = json.loads((ROOT / 'native/AppScope/app.json5').read_text())['app']['versionName']
        steps.append(('arkts-build', [sys.executable, 'native/tools/build_unsigned_formal.py',
                      '--output', str(output / f'quietstart-installer-{version}-unsigned.hap')], 900))
    results = []
    for name, command, timeout in steps:
        print(f'Checking {name}…', flush=True)
        start = time.monotonic()
        log = output / (name + '.log')
        code = -1
        with log.open('w') as handle:
            try:
                code = subprocess.run(command, cwd=ROOT, env=env, stdout=handle,
                                      stderr=subprocess.STDOUT, timeout=timeout).returncode
            except subprocess.TimeoutExpired:
                handle.write('\nGate timeout; process terminated.\n')
        results.append(dict(name=name, exit_code=code, seconds=round(time.monotonic() - start, 2), log=str(log)))
        print(f'{name}: {"PASS" if code == 0 else "FAIL"} ({results[-1]["seconds"]}s)', flush=True)
        if code != 0:
            # Keep full logs on disk; make the failing diagnostics visible in CI too.
            lines = log.read_text(errors='replace').splitlines()
            print('\n'.join(lines[-200:]), flush=True)
    summary = output / 'summary.json'
    summary.write_text(json.dumps(results, indent=2) + '\n')
    print(f'Results: {summary}', flush=True)
    return 0 if all(row['exit_code'] == 0 for row in results) else 1


if __name__ == '__main__':
    sys.exit(main())
