import 'package:flutter/material.dart';

/// Presentation only. IDs, states, totals and permissions come from the engine.
/// Selecting a table never opens or changes a restaurant order.
enum RestaurantTableState { free, occupied, payment }

class RestaurantTableView {
  const RestaurantTableView({
    required this.id,
    required this.name,
    required this.room,
    required this.state,
    this.guestsLabel,
    this.totalLabel,
    this.orderLabel,
    this.lines = const [],
  });
  final String id, name, room;
  final RestaurantTableState state;
  final String? guestsLabel, totalLabel, orderLabel;
  final List<RestaurantLineView> lines;
}

class RestaurantLineView {
  const RestaurantLineView({
    required this.name,
    required this.quantityLabel,
    required this.totalLabel,
    required this.stateLabel,
    this.note,
  });
  final String name, quantityLabel, totalLabel, stateLabel;
  final String? note;
}

class RestaurantStationView {
  const RestaurantStationView({
    required this.name,
    required this.destinationLabel,
    required this.statusLabel,
  });
  final String name, destinationLabel, statusLabel;
}

class RestaurantWorkspace extends StatefulWidget {
  const RestaurantWorkspace({
    super.key,
    required this.tables,
    this.stations = const [],
    required this.availabilityMessage,
    this.onOpen,
  });
  final List<RestaurantTableView> tables;
  final List<RestaurantStationView> stations;
  final String availabilityMessage;
  final void Function(RestaurantTableView)? onOpen;
  @override
  State<RestaurantWorkspace> createState() => _RestaurantWorkspaceState();
}

class _RestaurantWorkspaceState extends State<RestaurantWorkspace> {
  String? room, selectedId;
  String search = '';

  @override
  Widget build(BuildContext context) {
    final rooms = widget.tables.map((t) => t.room).toSet().toList()..sort();
    final activeRoom = rooms.contains(room) ? room : null;
    final visible = widget.tables
        .where(
          (t) =>
              (activeRoom == null || t.room == activeRoom) &&
              '${t.name} ${t.room}'.toLowerCase().contains(
                search.toLowerCase().trim(),
              ),
        )
        .toList();
    final selected = widget.tables.where((t) => t.id == selectedId).firstOrNull;
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 900;
        final floor = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Salle & tables',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              '${widget.tables.length} tables · ${widget.tables.where((t) => t.state != RestaurantTableState.free).length} occupées',
            ),
            const SizedBox(height: 20),
            TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                labelText: 'Rechercher une table ou une salle',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) => setState(() => search = value),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('Toutes les salles'),
                  selected: activeRoom == null,
                  onSelected: (_) => setState(() => room = null),
                ),
                for (final r in rooms)
                  ChoiceChip(
                    label: Text(r),
                    selected: activeRoom == r,
                    onSelected: (_) => setState(() => room = r),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            if (visible.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('Aucune table à afficher.'),
              ),
            LayoutBuilder(
              builder: (context, area) {
                final columns = area.maxWidth >= 760
                    ? 4
                    : area.maxWidth >= 540
                    ? 3
                    : area.maxWidth >= 340
                    ? 2
                    : 1;
                final width = (area.maxWidth - (columns - 1) * 12) / columns;
                return Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final table in visible)
                      SizedBox(width: width, child: _table(context, table)),
                  ],
                );
              },
            ),
            if (widget.stations.isNotEmpty) ...[
              const SizedBox(height: 28),
              const Text(
                'Cuisine & bar',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              for (final station in widget.stations)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.soup_kitchen_outlined),
                    title: Text(station.name),
                    subtitle: Text(
                      '${station.destinationLabel}\n${station.statusLabel}',
                    ),
                    isThreeLine: true,
                  ),
                ),
            ],
          ],
        );
        return SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline),
                      const SizedBox(width: 12),
                      Expanded(child: Text(widget.availabilityMessage)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              if (narrow) ...[
                floor,
                const SizedBox(height: 20),
                _detail(context, selected),
              ] else
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: floor),
                    const SizedBox(width: 24),
                    SizedBox(width: 340, child: _detail(context, selected)),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _table(BuildContext context, RestaurantTableView table) {
    final (label, icon, color) = switch (table.state) {
      RestaurantTableState.free => (
        'Libre',
        Icons.table_restaurant_outlined,
        const Color(0xff17634b),
      ),
      RestaurantTableState.occupied => (
        'En service',
        Icons.restaurant,
        const Color(0xff875a16),
      ),
      RestaurantTableState.payment => (
        'À encaisser',
        Icons.receipt_long_outlined,
        const Color(0xff354f9b),
      ),
    };
    final selected = selectedId == table.id;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(
          color: selected
              ? Theme.of(context).colorScheme.primary
              : const Color(0xffdce3df),
          width: selected ? 2 : 1,
        ),
      ),
      child: InkWell(
        onTap: () => setState(() => selectedId = table.id),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: color),
              const SizedBox(height: 12),
              Text(
                table.name,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(table.room, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 12),
              Text(
                label,
                style: TextStyle(color: color, fontWeight: FontWeight.w600),
              ),
              if (table.guestsLabel != null) Text(table.guestsLabel!),
              const SizedBox(height: 8),
              Text(
                table.totalLabel ?? '—',
                style: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _detail(BuildContext context, RestaurantTableView? table) => Card(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            table?.name ?? 'Votre sélection',
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          if (table == null)
            const Text('Choisissez une table pour consulter sa commande.')
          else ...[
            Text(table.orderLabel ?? 'Aucune commande ouverte'),
            const Divider(height: 32),
            for (final line in table.lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            '${line.quantityLabel} × ${line.name}',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(line.totalLabel),
                      ],
                    ),
                    if (line.note?.isNotEmpty ?? false) Text(line.note!),
                    Text(
                      line.stateLabel,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            if (table.totalLabel != null)
              Text(
                table.totalLabel!,
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                ),
              ),
          ],
          const SizedBox(height: 24),
          FilledButton(
            onPressed: table == null || widget.onOpen == null
                ? null
                : () => widget.onOpen!(table),
            child: Text('Ouvrir / modifier la commande'),
          ),
          if (widget.onOpen == null)
            const OutlinedButton(
              onPressed: null,
              child: Text('Envoyer en cuisine'),
            ),
          if (widget.onOpen == null)
            const OutlinedButton(onPressed: null, child: Text('Encaisser')),
          const SizedBox(height: 8),
          if (widget.onOpen == null)
            const Text(
              'Actions disponibles après raccordement du moteur restaurant.',
              style: TextStyle(fontSize: 12),
            ),
        ],
      ),
    ),
  );
}
