import 'package:flutter/material.dart';

class ShopikaissLogo extends StatelessWidget {
  const ShopikaissLogo({super.key, this.width = 210});
  final double width;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Image.asset(
      'assets/branding/shopikaiss/${dark ? 'SHOPIKAISS_01_Or_sur_noir.png' : 'SHOPIKAISS_02_Or_et_noir_sur_blanc.png'}',
      width: width,
      height: width * 192 / 700,
      fit: BoxFit.contain,
      semanticLabel: 'Shopikaiss',
    );
  }
}
