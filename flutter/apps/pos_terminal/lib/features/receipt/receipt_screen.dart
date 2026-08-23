import 'package:flutter/material.dart';

import '../../core/pos_core/models/canonical_receipt.dart';
import '../../core/pos_core/models/pos_core_failure.dart';
import '../../core/pos_core/pos_core_client.dart';
import 'canonical_receipt_view.dart';

String receiptFailureMessage(Object failure) {
  if (failure is PosCoreServerFailure) {
    return switch (failure.code) {
      'transaction_not_found' => 'Completed sale not found.',
      'receipt_not_available' =>
        'Receipt is not available because this transaction is not completed.',
      _ => 'Unable to load the completed sale receipt.',
    };
  }
  return 'Unable to load the completed sale receipt.';
}

class ReceiptScreen extends StatefulWidget {
  const ReceiptScreen({
    required this.client,
    required this.transactionId,
    super.key,
  });

  final PosCoreClient client;
  final String transactionId;

  @override
  State<ReceiptScreen> createState() => _ReceiptScreenState();
}

class _ReceiptScreenState extends State<ReceiptScreen> {
  CanonicalReceipt? _receipt;
  String? _failureMessage;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_loading) {
      return;
    }
    setState(() {
      _loading = true;
      _failureMessage = null;
    });
    try {
      final receipt = await widget.client.fetchReceipt(widget.transactionId);
      if (!mounted) {
        return;
      }
      setState(() {
        _receipt = receipt;
        _loading = false;
      });
    } on Object catch (failure) {
      if (!mounted) {
        return;
      }
      setState(() {
        _receipt = null;
        _failureMessage = receiptFailureMessage(failure);
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Completed Sale Receipt')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _receipt != null
          ? CanonicalReceiptView(receipt: _receipt!)
          : _ReceiptFailurePanel(
              message:
                  _failureMessage ??
                  'Unable to load the completed sale receipt.',
              onRetry: _load,
            ),
    );
  }
}

class _ReceiptFailurePanel extends StatelessWidget {
  const _ReceiptFailurePanel({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              liveRegion: true,
              child: Text(message, textAlign: TextAlign.center),
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
