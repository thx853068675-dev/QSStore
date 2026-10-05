"""Sign a device candidate through the same clean, unsigned release build path.

This never requests certificates or publishes the output.
"""
import argparse
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FORMAL_BUNDLE = 'com.tonghongxiang.hapstore'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('profile', 'cert', 'key', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--build-mode', choices=('release', 'debug'), default='release')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='qingqi-candidate-') as directory:
        unsigned = Path(directory) / 'candidate-unsigned.hap'
        subprocess.run([sys.executable, str(ROOT / 'tools/build_unsigned_formal.py'),
                        '--output', str(unsigned), '--build-mode', args.build_mode], check=True)
        subprocess.run([sys.executable, str(ROOT / 'tools/sign_preview.py'),
                        '--input', str(unsigned), '--profile', str(args.profile.resolve()),
                        '--cert', str(args.cert.resolve()), '--key', str(args.key.resolve()),
                        '--output', str(args.output.resolve()), '--bundle', FORMAL_BUNDLE], check=True)


if __name__ == '__main__':
    main()
