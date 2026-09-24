import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'authentication_controller.dart';

final class ChangePinDialog extends StatefulWidget {
  const ChangePinDialog({required this.controller, super.key});

  final AuthenticationController controller;

  @override
  State<ChangePinDialog> createState() => _ChangePinDialogState();
}

final class _ChangePinDialogState extends State<ChangePinDialog> {
  final _current = TextEditingController();
  final _newPin = TextEditingController();
  final _confirmation = TextEditingController();
  bool _pending = false;
  String? _error;

  @override
  void dispose() {
    _current.clear();
    _newPin.clear();
    _confirmation.clear();
    _current.dispose();
    _newPin.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_pending) return;
    final currentPin = _current.text;
    final newPin = _newPin.text;
    final confirmation = _confirmation.text;
    _current.clear();
    _newPin.clear();
    _confirmation.clear();
    if (newPin != confirmation) {
      setState(() => _error = 'New PIN entries do not match.');
      return;
    }
    setState(() {
      _pending = true;
      _error = null;
    });
    final outcome = await widget.controller.changePin(currentPin, newPin);
    if (!mounted) return;
    if (outcome == PinChangeOutcome.changed ||
        outcome == PinChangeOutcome.uncertain) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _pending = false;
      _error = switch (outcome) {
        PinChangeOutcome.policyRejected =>
          'Use 8–12 digits without simple repeated or sequential patterns.',
        PinChangeOutcome.credentialRejected =>
          'PIN change was not completed. Check your current PIN.',
        PinChangeOutcome.unavailable =>
          'POS Core is temporarily unavailable. Your PIN was not changed.',
        _ => 'PIN change was not completed.',
      };
    });
  }

  Widget _pinField(String label, Key key, TextEditingController controller) {
    return TextField(
      key: key,
      controller: controller,
      enabled: !_pending,
      obscureText: true,
      autocorrect: false,
      enableSuggestions: false,
      keyboardType: TextInputType.number,
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[0-9]')),
        LengthLimitingTextInputFormatter(12),
      ],
      decoration: InputDecoration(labelText: label),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Change PIN'),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'New PIN: 8–12 digits. Avoid repeated and sequential patterns.',
            ),
            _pinField('Current PIN', const Key('current-pin-input'), _current),
            _pinField('New PIN', const Key('new-pin-input'), _newPin),
            _pinField(
              'Confirm new PIN',
              const Key('confirm-new-pin-input'),
              _confirmation,
            ),
            if (_error case final message?) ...[
              const SizedBox(height: 12),
              Text(message, key: const Key('change-pin-error')),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _pending ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('change-pin-submit'),
          onPressed: _pending ? null : _submit,
          child: const Text('Change PIN'),
        ),
      ],
    );
  }
}
