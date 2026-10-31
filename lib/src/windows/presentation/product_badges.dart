import 'package:flutter/material.dart';

class ProductBadges extends StatelessWidget {
  const ProductBadges({super.key, required this.product});
  final Map<String, dynamic> product;
  @override
  Widget build(BuildContext context) {
    final labels = <String>[
      if (product['low_stock'] == true) 'Stock faible',
      if (product['promotion'] is String &&
          (product['promotion'] as String).isNotEmpty)
        product['promotion'] as String,
      if (product['is_new'] == true) 'Nouveau',
      if (product['favorite'] == true) '★ Favori',
    ];
    if (labels.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 24,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final label in labels)
            Tooltip(
              message: label,
              child: Container(
                margin: const EdgeInsets.only(right: 4),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: label == 'Stock faible'
                      ? const Color(0xffffedc2)
                      : const Color(0xffe3eee7),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  label,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xff27382f),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
