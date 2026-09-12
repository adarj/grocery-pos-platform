import 'dart:io';

const posCoreBaseUriEnvironmentKey = 'GROCERY_POS_CORE_BASE_URI';
const defaultPosCoreBaseUri = 'http://127.0.0.1:7340';

Uri resolvePosCoreBaseUri([Map<String, String>? environment]) {
  final values = environment ?? Platform.environment;
  final configured = values[posCoreBaseUriEnvironmentKey];
  final raw = configured ?? defaultPosCoreBaseUri;
  final uri = Uri.tryParse(raw);

  if (uri == null ||
      uri.scheme != 'http' ||
      !uri.hasAuthority ||
      (uri.host != '127.0.0.1' && uri.host != '::1') ||
      uri.userInfo.isNotEmpty ||
      uri.port < 1 ||
      uri.port > 65535 ||
      (uri.path.isNotEmpty && uri.path != '/') ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw FormatException(
      '$posCoreBaseUriEnvironmentKey must be an HTTP URI using literal '
      '127.0.0.1 or ::1 with no credentials, path, query, or fragment.',
    );
  }

  return uri;
}
