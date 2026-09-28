import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hapstore/net/api_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('签名身份接口同时携带华为登录凭证和账号资料凭证', () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      return http.Response(jsonEncode({
        'ok': true,
        'data': request.method == 'GET'
            ? {'identity': {'cert_id': '123', 'private_key_pem': 'pem'}}
            : {'created': true, 'cert_id': '123'},
      }), 200);
    });
    final api = ApiClient(baseUrl: 'https://example.invalid', client: client);
    api.authTokenProvider = () => 'jwt';
    api.authAccessTokenProvider = () => 'access';

    expect((await api.signingIdentity())['identity']['cert_id'], '123');
    await api.publishSigningIdentity('123', 'pem');
    expect(requests.length, 2);
    for (final request in requests) {
      expect(request.headers['authorization'], 'Bearer jwt');
      expect(request.headers['x-huawei-access-token'], 'access');
    }
    expect(jsonDecode(requests.last.body)['private_key_pem'], 'pem');
    api.dispose();
  });
}
