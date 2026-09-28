import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hapstore/net/api_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('管理页读取和删除本人应用时携带华为账号凭证', () async {
    final requests = <http.Request>[];
    final api = ApiClient(
      baseUrl: 'https://example.invalid',
      client: MockClient((request) async {
        requests.add(request);
        return http.Response(jsonEncode({
          'ok': true,
          'data': request.method == 'GET'
              ? {'items': [{'id': 7, 'repo': 'owner/repo',
                  'display_name': '实际应用名'}]}
              : {'removed': true, 'app_id': 7},
        }), 200, headers: {'content-type': 'application/json; charset=utf-8'});
      }),
    );
    api.authTokenProvider = () => 'jwt';
    api.authAccessTokenProvider = () => 'access';

    final apps = await api.myPublishedApps();
    expect(apps.single.displayName, '实际应用名');
    await api.removeMyPublishedApp(7);
    expect(requests.map((r) => '${r.method} ${r.url.path}').toList(), [
      'GET /api/v1/me/apps', 'DELETE /api/v1/me/apps/7',
    ]);
    for (final request in requests) {
      expect(request.headers['authorization'], 'Bearer jwt');
      expect(request.headers['x-huawei-access-token'], 'access');
    }
    api.dispose();
  });
}
