/// Shared decision used after a confirmed sale, outside the payment dialog.
Future<String> dispatchSaleTicket({
  required String mode,
  required Future<bool?> Function() confirm,
  required Future<String> Function() print,
}) async {
  if (mode != 'auto' && await confirm() != true) {
    return 'Ticket disponible dans Ventes récentes.';
  }
  return print();
}
