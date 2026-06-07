import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

void main() {
  runApp(
    PosTerminalApp(
      client: HttpPosCoreClient(
        baseUri: Uri.parse('http://127.0.0.1:7340'),
      ),
    ),
  );
}

class PosTerminalApp extends StatelessWidget {
  const PosTerminalApp({
    required this.client,
    super.key,
  });

  final PosCoreClient client;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Grocery POS Terminal',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
      ),
      home: PosCoreStatusScreen(client: client),
    );
  }
}

class PosCoreStatusScreen extends StatefulWidget {
  const PosCoreStatusScreen({
    required this.client,
    super.key,
  });

  final PosCoreClient client;

  @override
  State<PosCoreStatusScreen> createState() => _PosCoreStatusScreenState();
}

class _PosCoreStatusScreenState extends State<PosCoreStatusScreen> {
  late Future<PosCoreHealth> _healthFuture;

  @override
  void initState() {
    super.initState();
    _healthFuture = widget.client.fetchHealth();
  }

  void _retry() {
    setState(() {
      _healthFuture = widget.client.fetchHealth();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: FutureBuilder<PosCoreHealth>(
          future: _healthFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const _StatusLayout(
                title: 'Grocery POS Terminal',
                status: 'Connecting to POS Core...',
                detail: 'Checking http://127.0.0.1:7340/health',
                icon: Icons.sync,
              );
            }

            if (snapshot.hasError) {
              return _StatusLayout(
                title: 'Grocery POS Terminal',
                status: 'POS Core Unavailable',
                detail: snapshot.error.toString(),
                icon: Icons.error_outline,
                action: FilledButton.icon(
                  onPressed: _retry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
              );
            }

            final health = snapshot.data!;

            if (!health.ok) {
              return _StatusLayout(
                title: 'Grocery POS Terminal',
                status: 'POS Core Unavailable',
                detail: 'Health endpoint returned ok=false.',
                icon: Icons.warning_amber_outlined,
                action: FilledButton.icon(
                  onPressed: _retry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
              );
            }

            return _StatusLayout(
              title: 'Grocery POS Terminal',
              status: 'POS Core Connected',
              detail:
                  '${health.service} ${health.version} (${health.environment})',
              icon: Icons.check_circle_outline,
              action: FilledButton.icon(
                onPressed: _retry,
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh'),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _StatusLayout extends StatelessWidget {
  const _StatusLayout({
    required this.title,
    required this.status,
    required this.detail,
    required this.icon,
    this.action,
  });

  final String title;
  final String status;
  final String detail;
  final IconData icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 72),
                  const SizedBox(height: 24),
                  Text(
                    title,
                    style: textTheme.headlineMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    status,
                    style: textTheme.titleLarge,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    detail,
                    style: textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                  if (action != null) ...[
                    const SizedBox(height: 24),
                    action!,
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

abstract class PosCoreClient {
  Future<PosCoreHealth> fetchHealth();
}

class HttpPosCoreClient implements PosCoreClient {
  HttpPosCoreClient({
    required this.baseUri,
    http.Client? httpClient,
  }) : _httpClient = httpClient ?? http.Client();

  final Uri baseUri;
  final http.Client _httpClient;

  @override
  Future<PosCoreHealth> fetchHealth() async {
    final uri = baseUri.resolve('/health');

    final response = await _httpClient.get(uri).timeout(
          const Duration(seconds: 3),
        );

    if (response.statusCode != 200) {
      throw PosCoreUnavailableException(
        'Health check failed with HTTP ${response.statusCode}.',
      );
    }

    final decoded = jsonDecode(response.body);

    if (decoded is! Map<String, dynamic>) {
      throw const PosCoreUnavailableException(
        'Health check returned an invalid JSON payload.',
      );
    }

    return PosCoreHealth.fromJson(decoded);
  }
}

class PosCoreHealth {
  const PosCoreHealth({
    required this.ok,
    required this.service,
    required this.version,
    required this.environment,
  });

  final bool ok;
  final String service;
  final String version;
  final String environment;

  factory PosCoreHealth.fromJson(Map<String, dynamic> json) {
    return PosCoreHealth(
      ok: json['ok'] == true,
      service: json['service'] as String? ?? 'unknown-service',
      version: json['version'] as String? ?? 'unknown-version',
      environment: json['environment'] as String? ?? 'unknown-environment',
    );
  }
}

class PosCoreUnavailableException implements Exception {
  const PosCoreUnavailableException(this.message);

  final String message;

  @override
  String toString() => message;
}
