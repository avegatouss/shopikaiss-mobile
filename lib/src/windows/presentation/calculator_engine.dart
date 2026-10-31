/// Exact fractions until display, rounded to 12 decimal places. No sale data.
String calculateExpression(String expression) {
  if (expression.length > 256) throw const FormatException('Calcul trop long');
  final p = _Parser(
    expression
        .replaceAll(' ', '')
        .replaceAll(',', '.')
        .replaceAll('×', '*')
        .replaceAll('÷', '/')
        .replaceAll('−', '-'),
  );
  final result = p.sum();
  if (p.position != p.source.length) {
    throw const FormatException('Calcul incomplet');
  }
  return result.value.display();
}

class _Number {
  _Number(BigInt numerator, [BigInt? denominator])
    : n = numerator,
      d = denominator ?? BigInt.one {
    if (d == BigInt.zero) {
      throw const FormatException('Division par zéro impossible');
    }
    if (d.isNegative) {
      n = -n;
      d = -d;
    }
    final common = n.abs().gcd(d);
    n ~/= common;
    d ~/= common;
  }
  BigInt n, d;
  _Number operator +(_Number b) => _Number(n * b.d + b.n * d, d * b.d);
  _Number operator -(_Number b) => _Number(n * b.d - b.n * d, d * b.d);
  _Number operator *(_Number b) => _Number(n * b.n, d * b.d);
  _Number operator /(_Number b) => _Number(n * b.d, d * b.n);
  String display() {
    final absolute = n.abs() * BigInt.from(10).pow(12);
    var rounded = absolute ~/ d;
    if ((absolute % d) * BigInt.two >= d) rounded += BigInt.one;
    var text = rounded.toString().padLeft(13, '0');
    text =
        '${text.substring(0, text.length - 12)}.${text.substring(text.length - 12)}'
            .replaceFirst(RegExp(r'\.?0+$'), '');
    if (text.length > 128) throw const FormatException('Résultat trop grand');
    return '${n.isNegative && rounded != BigInt.zero ? '-' : ''}$text'
        .replaceAll('.', ',');
  }
}

class _Value {
  _Value(this.value, [this.percent = false]);
  final _Number value;
  final bool percent;
}

class _Parser {
  _Parser(this.source);
  final String source;
  int position = 0;
  bool take(String c) {
    if (position < source.length && source[position] == c) {
      position++;
      return true;
    }
    return false;
  }

  _Value sum() {
    var left = product();
    while (position < source.length && '+-'.contains(source[position])) {
      final op = source[position++];
      final right = product();
      // Conventional relative percentage: 200 + 10% = 220.
      final amount = right.percent ? left.value * right.value : right.value;
      left = _Value(op == '+' ? left.value + amount : left.value - amount);
    }
    return left;
  }

  _Value product() {
    var left = atom();
    while (position < source.length && '*/'.contains(source[position])) {
      final op = source[position++];
      final right = atom();
      left = _Value(
        op == '*' ? left.value * right.value : left.value / right.value,
      );
    }
    return left;
  }

  _Value atom() {
    if (take('+')) return atom();
    if (take('-')) {
      final v = atom();
      return _Value(_Number(BigInt.zero) - v.value, v.percent);
    }
    _Value result;
    if (take('(')) {
      result = sum();
      if (!take(')')) throw const FormatException('Fermez la parenthèse');
    } else {
      final start = position;
      while (position < source.length &&
          '0123456789.'.contains(source[position])) {
        position++;
      }
      final text = source.substring(start, position);
      if (!RegExp(r'^(\d+(\.\d*)?|\.\d+)$').hasMatch(text)) {
        throw const FormatException('Calcul incomplet');
      }
      final parts = text.split('.');
      result = _Value(
        _Number(
          BigInt.parse(text.replaceAll('.', '')),
          BigInt.from(10).pow(parts.length == 2 ? parts[1].length : 0),
        ),
      );
    }
    if (take('%')) {
      return _Value(result.value / _Number(BigInt.from(100)), true);
    }
    return result;
  }
}
