import 'package:flutter_test/flutter_test.dart';
import 'package:pos_terminal/core/pos_core/pos_core_endpoint.dart';

void main() {
  test('missing environment override preserves the development endpoint', () {
    expect(resolvePosCoreBaseUri(const {}), Uri.parse(defaultPosCoreBaseUri));
  });

  test('literal IPv4 and IPv6 loopback endpoints are accepted', () {
    expect(
      resolvePosCoreBaseUri(const {
        posCoreBaseUriEnvironmentKey: 'http://127.0.0.1:7440',
      }),
      Uri.parse('http://127.0.0.1:7440'),
    );
    expect(
      resolvePosCoreBaseUri(const {
        posCoreBaseUriEnvironmentKey: 'http://[::1]:7441',
      }),
      Uri.parse('http://[::1]:7441'),
    );
    expect(
      resolvePosCoreBaseUri(const {
        posCoreBaseUriEnvironmentKey: 'http://127.0.0.1',
      }).port,
      80,
    );
  });

  test('remote addresses and DNS names are rejected', () {
    for (final value in <String>[
      'http://localhost:7340',
      'http://192.168.1.10:7340',
      'http://0.0.0.0:7340',
      'http://[::]:7340',
      'https://127.0.0.1:7340',
    ]) {
      expect(
        () => resolvePosCoreBaseUri({posCoreBaseUriEnvironmentKey: value}),
        throwsA(isA<FormatException>()),
        reason: value,
      );
    }
  });

  test('credentials and non-base URI components are rejected', () {
    for (final value in <String>[
      'http://cashier:secret@127.0.0.1:7340',
      'http://127.0.0.1:7340/api',
      'http://127.0.0.1:7340?debug=true',
      'http://127.0.0.1:7340#fragment',
      'not a uri',
      '',
    ]) {
      expect(
        () => resolvePosCoreBaseUri({posCoreBaseUriEnvironmentKey: value}),
        throwsA(isA<FormatException>()),
        reason: value,
      );
    }
  });
}
