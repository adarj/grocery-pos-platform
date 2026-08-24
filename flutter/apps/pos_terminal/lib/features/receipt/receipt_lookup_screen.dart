import 'package:flutter/material.dart';

import '../../core/pos_core/models/canonical_receipt.dart';
import '../../core/pos_core/pos_core_client.dart';
import 'canonical_receipt_view.dart';
import 'receipt_screen.dart';

class ReceiptLookupScreen extends StatefulWidget {
  const ReceiptLookupScreen({required this.client, super.key});

  final PosCoreClient client;

  @override
  State<ReceiptLookupScreen> createState() => _ReceiptLookupScreenState();
}

class _ReceiptLookupScreenState extends State<ReceiptLookupScreen> {
  final _transactionIdController = TextEditingController();
  CanonicalReceipt? _receipt;
  String? _failureMessage;
  String? _lastSubmittedTransactionId;
  bool _loading = false;

  @override
  void dispose() {
    _transactionIdController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final transactionId = _transactionIdController.text;
    if (transactionId.isEmpty) {
      setState(() {
        _receipt = null;
        _failureMessage = 'Enter a transaction ID.';
      });
      return;
    }
    await _load(transactionId);
  }

  Future<void> _load(String transactionId) async {
    if (_loading) {
      return;
    }
    setState(() {
      _loading = true;
      _receipt = null;
      _failureMessage = null;
      _lastSubmittedTransactionId = transactionId;
    });
    try {
      final receipt = await widget.client.fetchReceipt(transactionId);
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
        _failureMessage = receiptFailureMessage(failure);
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Lookup Completed Sale')),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('receipt-transaction-id-field'),
                      controller: _transactionIdController,
                      enabled: !_loading,
                      autocorrect: false,
                      enableSuggestions: false,
                      smartDashesType: SmartDashesType.disabled,
                      smartQuotesType: SmartQuotesType.disabled,
                      textInputAction: TextInputAction.search,
                      onSubmitted: _loading ? null : (_) => _submit(),
                      decoration: const InputDecoration(
                        labelText: 'Transaction ID',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: _loading ? null : _submit,
                    child: const Text('Find Receipt'),
                  ),
                ],
              ),
            ),
            Expanded(child: _buildResult()),
          ],
        ),
      ),
    );
  }

  Widget _buildResult() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_receipt != null) {
      return CanonicalReceiptView(receipt: _receipt!);
    }
    if (_failureMessage != null) {
      final retryId = _lastSubmittedTransactionId;
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                liveRegion: true,
                child: Text(_failureMessage!, textAlign: TextAlign.center),
              ),
              if (retryId != null) ...[
                const SizedBox(height: 16),
                OutlinedButton(
                  onPressed: () => _load(retryId),
                  child: const Text('Retry'),
                ),
              ],
            ],
          ),
        ),
      );
    }
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text('Enter the exact transaction ID for a completed sale.'),
      ),
    );
  }
}
