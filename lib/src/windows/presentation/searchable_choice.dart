import 'package:flutter/material.dart';

class SearchableChoice extends StatelessWidget {
  const SearchableChoice({
    super.key,
    required this.label,
    required this.all,
    required this.values,
    required this.selected,
    this.onChanged,
  });
  final String label, all, selected;
  final List<String> values;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onChanged == null
        ? null
        : () async {
            var query = '';
            final result = await showDialog<String>(
              context: context,
              builder: (context) => StatefulBuilder(
                builder: (context, setState) {
                  final matches = values
                      .toSet()
                      .where(
                        (v) =>
                            v.isNotEmpty &&
                            v.toLowerCase().contains(
                              query.trim().toLowerCase(),
                            ),
                      )
                      .toList();
                  return AlertDialog(
                    title: Text(label),
                    content: SizedBox(
                      width: 460,
                      height: 360,
                      child: Column(
                        children: [
                          TextField(
                            autofocus: true,
                            decoration: InputDecoration(
                              labelText: 'Rechercher : $label',
                              prefixIcon: const Icon(Icons.search),
                            ),
                            onChanged: (v) => setState(() => query = v),
                          ),
                          ListTile(
                            title: Text(all),
                            selected: selected.isEmpty,
                            onTap: () => Navigator.pop(context, ''),
                          ),
                          Expanded(
                            child: matches.isEmpty
                                ? const Center(child: Text('Aucun résultat'))
                                : ListView.builder(
                                    itemCount: matches.length,
                                    itemBuilder: (context, i) => ListTile(
                                      title: Text(matches[i]),
                                      selected: selected == matches[i],
                                      onTap: () =>
                                          Navigator.pop(context, matches[i]),
                                    ),
                                  ),
                          ),
                        ],
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Fermer'),
                      ),
                    ],
                  );
                },
              ),
            );
            if (result != null) onChanged?.call(result);
          },
    child: InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        enabled: onChanged != null,
        suffixIcon: const Icon(Icons.arrow_drop_down),
      ),
      child: Text(
        selected.isEmpty ? all : selected,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    ),
  );
}
