"""Build and sign a same-bundle device candidate, restoring preview sources.

The formal package is only suitable for the device named in its AGC debug
profile. This script never requests a certificate or publishes the output.
"""

import argparse
import os
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'AppScope/app.json5'
HVIGOR = Path('/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw')
PREVIEW_BUNDLE = 'com.tonghongxiang.hapstore.nativepreview'
FORMAL_BUNDLE = 'com.tonghongxiang.hapstore'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profile', type=Path, required=True)
    parser.add_argument('--cert', type=Path, required=True)
    parser.add_argument('--key', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    original = APP.read_text()
    if original.count(PREVIEW_BUNDLE) != 1 or 'native-preview' not in original:
        raise ValueError('Expected the checked-in preview app identity')
    formal = original.replace(PREVIEW_BUNDLE, FORMAL_BUNDLE)
    formal = formal.replace('native-preview', 'native')
    environment = dict(os.environ)
    environment.setdefault('DEVECO_SDK_HOME', '/Applications/DevEco-Studio.app/Contents/sdk')
    environment.setdefault('JAVA_HOME',
                           '/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home')
    try:
        APP.write_text(formal)
        subprocess.run([str(HVIGOR), 'assembleHap', '-p', 'product=default',
                        '-p', 'buildMode=debug', '--no-daemon'], cwd=ROOT,
                       env=environment, check=True)
        subprocess.run([sys.executable, str(ROOT / 'tools/sign_preview.py'),
                        '--input', str(ROOT / 'entry/build/default/outputs/default/entry-default-unsigned.hap'),
                        '--profile', str(args.profile), '--cert', str(args.cert),
                        '--key', str(args.key), '--output', str(args.output),
                        '--bundle', FORMAL_BUNDLE], cwd=ROOT, check=True)
    finally:
        APP.write_text(original)


if __name__ == '__main__':
    main()
