import 'package:flutter/material.dart';

import '../../core/pos_core/models/canonical_receipt.dart';
import '../cashier/cashier_money_format.dart';

class CanonicalReceiptView extends StatelessWidget {
  const CanonicalReceiptView({required this.receipt, super.key});

  final CanonicalReceipt receipt;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                header: true,
                child: Text('Receipt', style: theme.textTheme.headlineMedium),
              ),
              const SizedBox(height: 8),
              Text(
                'Transaction: ${receipt.transactionId}',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 24),
              for (final line in receipt.lineItems) ...[
                _ReceiptLine(line: line),
                const Divider(height: 24),
              ],
              _ReceiptMoneyRow(
                label: 'Subtotal',
                minorUnits: receipt.subtotalMinorUnits,
              ),
              _ReceiptMoneyRow(label: 'Tax', minorUnits: receipt.taxMinorUnits),
              const SizedBox(height: 8),
              _ReceiptMoneyRow(
                label: 'Total',
                minorUnits: receipt.totalMinorUnits,
                emphasized: true,
              ),
              const SizedBox(height: 20),
              _ReceiptMoneyRow(
                label: 'Cash',
                minorUnits: receipt.tenderedCashMinorUnits,
              ),
              _ReceiptMoneyRow(
                label: 'Change',
                minorUnits: receipt.changeDueMinorUnits,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReceiptLine extends StatelessWidget {
  const _ReceiptLine({required this.line});

  final CanonicalReceiptLine line;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      label:
          '${line.description}, ${line.barcode}, '
          '${formatUsdMinorUnits(line.unitPriceMinorUnits)}, '
          'line tax ${formatUsdMinorUnits(line.taxAmountMinorUnits)}',
      child: ExcludeSemantics(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(line.description, style: theme.textTheme.titleMedium),
                  const SizedBox(height: 2),
                  Text(line.barcode, style: theme.textTheme.bodySmall),
                  const SizedBox(height: 4),
                  Text(
                    'Line tax ${formatUsdMinorUnits(line.taxAmountMinorUnits)}',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Text(
              formatUsdMinorUnits(line.unitPriceMinorUnits),
              style: theme.textTheme.titleMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _ReceiptMoneyRow extends StatelessWidget {
  const _ReceiptMoneyRow({
    required this.label,
    required this.minorUnits,
    this.emphasized = false,
  });

  final String label;
  final int minorUnits;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final text = '$label ${formatUsdMinorUnits(minorUnits)}';
    return Semantics(
      label: text,
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            text,
            textAlign: TextAlign.end,
            style: emphasized
                ? Theme.of(context).textTheme.headlineSmall
                : Theme.of(context).textTheme.titleMedium,
          ),
        ),
      ),
    );
  }
}
