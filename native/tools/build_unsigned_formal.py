"""Build a formal-bundle unsigned HAP for device-side signing.

The source app identity is restored even when hvigor fails. This produces a
download artifact, not an installable HAP. A side-loading tool must sign it for
the user's device; preserving old app data requires a compatible signing identity.
"""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
from verify_unsigned_hap import verify_unsigned


ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'AppScope/app.json5'
OUTPUT = ROOT / 'entry/build/default/outputs/default/entry-default-unsigned.hap'
HVIGOR = Path('/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw')
PREVIEW_BUNDLE = 'com.tonghongxiang.hapstore.nativepreview'
FORMAL_BUNDLE = 'com.tonghongxiang.hapstore'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--version-code', type=int)
    parser.add_argument('--version-name')
    parser.add_argument('--build-mode', choices=('release', 'debug'), default='release',
                        help='Release omits packaged source maps; debug is for local diagnosis')
    args = parser.parse_args()
    original = APP.read_text()
    document = json.loads(original)
    app = document['app']
    if app['bundleName'] != PREVIEW_BUNDLE:
        raise ValueError('Checked-in app identity is not the preview bundle')
    app['bundleName'] = FORMAL_BUNDLE
    if args.version_code is not None:
        if args.version_code <= 0:
            raise ValueError('version-code must be positive')
        app['versionCode'] = args.version_code
    if args.version_name is not None:
        if not args.version_name or len(args.version_name) > 64:
            raise ValueError('version-name is invalid')
        app['versionName'] = args.version_name
    environment = dict(os.environ)
    environment.setdefault('DEVECO_SDK_HOME', '/Applications/DevEco-Studio.app/Contents/sdk')
    environment.setdefault('JAVA_HOME',
                           '/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home')
    node = '/Applications/DevEco-Studio.app/Contents/tools/node/bin'
    environment['PATH'] = node + os.pathsep + environment.get('PATH', '')
    try:
        APP.write_text(json.dumps(document, ensure_ascii=False, indent=2) + '\n')
        # Hvigor may cache the native task without seeing sibling Rust sources.
        # A release must reach Ninja/Cargo even after a Rust-only change.
        subprocess.run([str(HVIGOR), 'clean', '--no-daemon'], cwd=ROOT,
                       env=environment, check=True)
        subprocess.run([str(HVIGOR), 'assembleHap', '-p', 'product=default',
                        '-p', 'buildMode=' + args.build_mode, '--no-daemon'], cwd=ROOT,
                       env=environment, check=True)
        if not OUTPUT.is_file():
            raise FileNotFoundError(OUTPUT)
        checked = verify_unsigned(OUTPUT)
        print('Verified unsigned outer/embedded packages:', len(checked))
        args.output.parent.mkdir(parents=True, exist_ok=True)
        staging = args.output.with_suffix(args.output.suffix + '.tmp')
        shutil.copyfile(OUTPUT, staging)
        staging.replace(args.output)
    finally:
        APP.write_text(original)


if __name__ == '__main__':
    main()
