/// Add a whole sale unit without floating point rounding. The engine checks
/// stock, permitted precision and product-specific quantity rules afterwards.
String? steppedQuantity(Object? value, int step) {
  final text = value?.toString().replaceAll(',', '.') ?? '';
  if (!RegExp(r'^\d+(\.\d{1,6})?$').hasMatch(text)) return null;
  final parts = text.split('.');
  final digits = parts.length == 2 ? parts[1].length : 0;
  final scale = BigInt.from(10).pow(digits);
  final current = BigInt.parse(parts[0]) * scale + (digits == 0 ? BigInt.zero : BigInt.parse(parts[1]));
  final next = current + BigInt.from(step) * scale;
  if (next <= BigInt.zero) return null;
  final whole = next ~/ scale;
  if (digits == 0) return '$whole';
  final fraction = (next % scale).toString().padLeft(digits, '0').replaceFirst(RegExp(r'0+$'), '');
  return fraction.isEmpty ? '$whole' : '$whole.$fraction';
}
