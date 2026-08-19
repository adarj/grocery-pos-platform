import 'package:flutter/material.dart';

import 'app/pos_terminal_app.dart';
import 'core/pos_core/http_pos_core_client.dart';

void main() {
  final client = HttpPosCoreClient(baseUri: Uri.parse('http://127.0.0.1:7340'));

  runApp(PosTerminalApp(client: client));
}
