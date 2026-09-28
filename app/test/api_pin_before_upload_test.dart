import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hapstore/net/api_client.dart';

void main() {
  test('错误证书在上传签名私钥前被拒绝，即使系统信任该证书', () async {
    final dir = await Directory.systemTemp.createTemp('starstore-pin-test-');
    HttpServer? server;
    try {
      final cert = File('${dir.path}/cert.pem');
      final key = File('${dir.path}/key.pem');
      final generated = await Process.run('openssl', [
        'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
        '-subj', '/CN=127.0.0.1', '-addext', 'subjectAltName=IP:127.0.0.1',
        '-keyout', key.path, '-out', cert.path,
      ]);
      expect(generated.exitCode, 0, reason: '${generated.stderr}');

      // 模拟被系统 CA 信任、但与内置 pin 不同的证书。
      SecurityContext.defaultContext
          .setTrustedCertificatesBytes(await cert.readAsBytes());
      final context = SecurityContext()
        ..useCertificateChain(cert.path)
        ..usePrivateKey(key.path);
      server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0,
          context);
      var uploaded = false;
      server.listen((request) async {
        uploaded = true;
        await request.drain<void>();
        request.response
          ..statusCode = HttpStatus.ok
          ..write('{"ok":true,"data":{"created":true}}');
        await request.response.close();
      });

      final api = ApiClient(baseUrl: 'https://127.0.0.1:${server.port}');
      api.authTokenProvider = () => 'test-jwt';
      api.authAccessTokenProvider = () => 'test-access';
      try {
        await expectLater(
          api.publishSigningIdentity('123', 'PRIVATE KEY TEST DATA'),
          throwsA(isA<ApiException>()),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(uploaded, isFalse);
      } finally {
        api.dispose();
      }
    } finally {
      await server?.close(force: true);
      await dir.delete(recursive: true);
    }
  });
}
