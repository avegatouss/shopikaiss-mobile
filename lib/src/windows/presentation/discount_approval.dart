import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'register_controller.dart';

/// The secret lives only during this attempt; durable intents contain its UUID,
/// never the authorization code. An uncertain sale is reconciled, not retried.
Future<bool> commitWithApproval(
  BuildContext context,
  WindowsRegisterController c,
) async {
  final requirement = c.view['discount_approval'];
  if (requirement is! Map || requirement['required'] != true) {
    await c.commitSale();
    return true;
  }
  final draft = c.view['draft_id'];
  final revision = c.view['revision'];
  final approvers = (requirement['approvers'] as List? ?? const [])
      .whereType<Map>()
      .toList();
  var code = '';
  var reason = '';
  Object? approver;
  Map<String, dynamic>? approval;
  try {
    approval = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          scrollable: true,
          title: const Text('Autorisation du responsable'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Cette remise dépasse votre plafond. Le responsable doit autoriser cette vente.',
                ),
                DropdownButtonFormField<Object>(
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Responsable'),
                  items: [
                    for (final item in approvers)
                      DropdownMenuItem(
                        value: item['id'],
                        child: Text('${item['name']}'),
                      ),
                  ],
                  onChanged: (value) => setState(() => approver = value),
                ),
                TextField(
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(8),
                  ],
                  decoration: const InputDecoration(
                    labelText: 'Code du responsable (8 chiffres)',
                  ),
                  onChanged: (value) => setState(() => code = value),
                ),
                TextField(
                  maxLength: 500,
                  decoration: const InputDecoration(
                    labelText: 'Motif de la remise',
                  ),
                  onChanged: (value) => setState(() => reason = value),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed:
                  approver != null &&
                      code.length == 8 &&
                      reason.trim().isNotEmpty
                  ? () => Navigator.pop(context, <String, dynamic>{
                      'approver_id': approver,
                      'code': code,
                      'reason': reason.trim(),
                    })
                  : null,
              child: const Text('Autoriser et encaisser'),
            ),
          ],
        ),
      ),
    );
    code = '';
    reason = '';
    if (approval == null) return false;
    if (!context.mounted ||
        !c.canPay ||
        c.view['draft_id'] != draft ||
        c.view['revision'] != revision) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'La caisse a changé. Vérifiez le panier avant de redemander une autorisation.',
            ),
          ),
        );
      }
      return false;
    }
    await c.commitSale(approval: approval);
    return true;
  } finally {
    approval?.clear();
    code = '';
    reason = '';
  }
}
