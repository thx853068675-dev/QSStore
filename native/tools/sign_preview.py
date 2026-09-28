"""Sign an ArkTS device candidate with existing, externally held materials.

The key, certificate, profile and temporary PKCS12 never enter this repository.
Use an already paired AGC certificate; this script never requests a new slot.
"""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile


SDK = Path('/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains')
JAVA = Path('/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home/bin/java')
JAR = SDK / 'lib/hap-sign-tool.jar'


def checked(args):
    result = subprocess.run(args, capture_output=True)
    if result.returncode:
        raise RuntimeError(f'{Path(args[0]).name} failed with status {result.returncode}')
    return result.stdout


def profile_bundle(profile):
    payload = checked(['openssl', 'cms', '-verify', '-inform', 'DER', '-noverify',
                       '-in', str(profile)])
    return json.loads(payload)['bundle-info']['bundle-name']


def hap_bundle(hap):
    with zipfile.ZipFile(hap) as archive:
        module = json.loads(archive.read('module.json'))
        pack = json.loads(archive.read('pack.info'))
    first = module['app']['bundleName']
    second = pack['summary']['app']['bundleName']
    if first != second:
        raise ValueError('HAP module.json and pack.info bundle names disagree')
    return first


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', type=Path, required=True)
    parser.add_argument('--profile', type=Path, required=True)
    parser.add_argument('--cert', type=Path, required=True)
    parser.add_argument('--key', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--bundle', choices=[
        'com.tonghongxiang.hapstore.nativepreview',
        'com.tonghongxiang.hapstore',
    ], default='com.tonghongxiang.hapstore.nativepreview')
    args = parser.parse_args()
    if hap_bundle(args.input) != args.bundle:
        raise ValueError('HAP bundle does not match the requested candidate')
    if profile_bundle(args.profile) != hap_bundle(args.input):
        raise ValueError('AGC profile does not belong to the HAP bundle')
    password = os.environ.get('QINGQI_SIGN_PASSWORD', '123456')
    with tempfile.TemporaryDirectory(prefix='qingqi-sign-') as temp:
        temporary = Path(temp)
        keystore = temporary / 'preview.p12'
        signed = temporary / 'signed.hap'
        checked(['openssl', 'pkcs12', '-export', '-inkey', str(args.key), '-in',
                 str(args.cert), '-out', str(keystore), '-name', 'qingqi-preview',
                 '-passout', 'pass:' + password])
        checked([str(JAVA), '-jar', str(JAR), 'sign-app', '-mode', 'localSign',
                 '-keyAlias', 'qingqi-preview', '-appCertFile', str(args.cert),
                 '-profileFile', str(args.profile), '-inFile', str(args.input),
                 '-signAlg', 'SHA256withECDSA', '-keystoreFile', str(keystore),
                 '-keystorePwd', password, '-keyPwd', password,
                 '-outFile', str(signed), '-compatibleVersion', '24'])
        checked([str(JAVA), '-jar', str(JAR), 'verify-app', '-inFile', str(signed),
                 '-outCertChain', str(temporary / 'chain.cer'),
                 '-outProfile', str(temporary / 'profile.p7b')])
        args.output.parent.mkdir(parents=True, exist_ok=True)
        staging = args.output.with_suffix(args.output.suffix + '.tmp')
        shutil.copyfile(signed, staging)
        staging.replace(args.output)
    print('Signed and verified native candidate:', args.output)


if __name__ == '__main__':
    main()
