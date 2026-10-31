import 'package:flutter/material.dart';

/// Displays feedback inside the payment dialog rather than behind its modal.
class PaymentMessage extends StatelessWidget {
  const PaymentMessage({super.key, required this.message});
  final String? message;
  @override
  Widget build(BuildContext context) => message == null
      ? const SizedBox.shrink()
      : Semantics(
          liveRegion: true,
          child: Container(
            width: double.infinity,
            margin: const EdgeInsets.only(top: 12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              message!,
              style: TextStyle(
                fontSize: 14,
                color: Theme.of(context).colorScheme.onErrorContainer,
              ),
            ),
          ),
        );
}
