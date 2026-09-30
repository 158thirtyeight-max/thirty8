import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/supabase_providers.dart';
import 'fleet_providers.dart';
import 'seat_layout_model.dart';

/// Active layout row plus its seats for one bus (layout null when none saved).
final busLayoutProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, busId) async {
  final db = ref.watch(supabaseProvider);
  final layout = await db
      .from('bus_layouts')
      .select()
      .eq('bus_id', busId)
      .eq('is_active', true)
      .order('version', ascending: false)
      .limit(1)
      .maybeSingle();
  if (layout == null) return {'layout': null, 'seats': <Map<String, dynamic>>[]};
  final seats = await db.from('seats').select().eq('bus_layout_id', layout['id'] as String);
  return {'layout': layout, 'seats': List<Map<String, dynamic>>.from(seats)};
});

enum _Tool { seat, sleeper, premium, unavailable, reserved, crew, other, erase }

/// Stage C — visual seat layout editor for one bus. Cells are painted with the
/// selected tool; aisle columns and grid size are configurable; two decks are
/// available for sleeper / semi-sleeper buses (deck 1 = lower, deck 2 = upper
/// berths). Structural rules are shown live; the server re-validates on save,
/// submit, approval and activation.
class StageSeatLayoutScreen extends ConsumerStatefulWidget {
  const StageSeatLayoutScreen({super.key, required this.operatorId, required this.bus});

  final String operatorId;
  final Map<String, dynamic> bus;

  @override
  ConsumerState<StageSeatLayoutScreen> createState() => _StageSeatLayoutScreenState();
}

class _StageSeatLayoutScreenState extends ConsumerState<StageSeatLayoutScreen> {
  LayoutConfig _config = const LayoutConfig(rows: 10, cols: 5, decks: 1, aisleCols: {3});
  Map<CellKey, SeatCell> _cells = {};
  _Tool _tool = _Tool.seat;
  int _deck = 1;
  bool _loaded = false;
  bool _saving = false;
  bool _dirty = false;
  String? _error;
  List<String> _serverErrors = const [];

  String get _busType => widget.bus['bus_type'] as String;
  String get _seating => seatingOf(_busType);
  int get _capacity => widget.bus['total_seats'] as int;

  bool get _editable {
    final lifecycle = widget.bus['lifecycle_status'] as String?;
    return widget.bus['is_legacy'] == true || lifecycle == 'draft' || lifecycle == 'changes_requested';
  }

  void _load(Map<String, dynamic> data) {
    if (_loaded) return;
    _loaded = true;
    final layout = data['layout'] as Map<String, dynamic>?;
    final seats = List<Map<String, dynamic>>.from(data['seats'] as List);
    if (layout == null || seats.isEmpty) return;

    final cfg = LayoutConfig.fromJson(
      (layout['layout_json'] as Map?)?.cast<String, dynamic>(),
      deckCount: layout['deck_count'] as int,
    );
    if (cfg == null) {
      // Layout created by the previous bus form: convert once, user saves to persist.
      final converted = convertLegacySeats(seats, busType: _busType);
      _config = converted.config;
      _cells = converted.cells;
      _dirty = true;
      return;
    }
    _config = cfg;
    _cells = {
      for (final s in seats)
        (s['deck'] as int, s['row_no'] as int, s['col_no'] as int): SeatCell(
          kind: SeatKindX.parse(s['kind'] as String?),
          sleeper: s['seat_type'] == 'sleeper',
          category: s['category'] as String?,
        ),
    };
  }

  void _paint(int row, int col) {
    if (!_editable || _saving) return;
    final key = (_deck, row, col);
    setState(() {
      _dirty = true;
      if (_tool == _Tool.erase) {
        _cells = {..._cells}..remove(key);
        return;
      }
      final kind = switch (_tool) {
        _Tool.seat || _Tool.sleeper || _Tool.premium => SeatKind.bookable,
        _Tool.unavailable => SeatKind.unavailable,
        _Tool.reserved => SeatKind.reserved,
        _Tool.crew => SeatKind.crew,
        _Tool.other => SeatKind.other,
        _Tool.erase => SeatKind.bookable,
      };
      final sleeper = switch (_seating) {
        'sleeper' => true,
        'seater' => false,
        _ => _tool == _Tool.sleeper || (_cells[key]?.sleeper ?? false) && _tool != _Tool.seat,
      };
      final category = switch (_tool) {
        _Tool.premium => 'premium',
        _Tool.seat || _Tool.sleeper => null,
        _ => _cells[key]?.category,
      };
      _cells = {..._cells, key: SeatCell(kind: kind, sleeper: sleeper, category: category)};
    });
  }

  void _resize({int? rows, int? cols, int? decks}) {
    setState(() {
      _dirty = true;
      _config = _config.copyWith(rows: rows, cols: cols, decks: decks);
      if (decks != null && _deck > decks) _deck = decks;
      _cells = {
        for (final e in _cells.entries)
          if (e.key.$2 <= _config.rows && e.key.$3 <= _config.cols && e.key.$1 <= _config.decks) e.key: e.value,
      };
      _config = _config.copyWith(aisleCols: _config.aisleCols.where((c) => c <= _config.cols).toSet());
    });
  }

  void _toggleAisle(int col) {
    setState(() {
      _dirty = true;
      final a = {..._config.aisleCols};
      if (!a.add(col)) a.remove(col);
      _config = _config.copyWith(aisleCols: a);
      _cells = {
        for (final e in _cells.entries)
          if (!a.contains(e.key.$3)) e.key: e.value,
      };
    });
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final res = await ref.read(supabaseProvider).rpc('save_bus_layout', params: {
        'p_bus_id': widget.bus['id'],
        'p_layout': _config.toJson(),
        'p_seats': seatsToJson(_config, _cells, _busType),
      });
      final map = Map<String, dynamic>.from(res as Map);
      ref.invalidate(busLayoutProvider(widget.bus['id'] as String));
      setState(() {
        _dirty = false;
        _serverErrors = List<String>.from(map['errors'] as List);
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(_serverErrors.isEmpty ? 'Seat layout saved.' : 'Saved — but the layout still has issues to fix.'),
        ));
      }
    } catch (e) {
      final m = e.toString();
      setState(() => _error = m.contains('locked') ? 'The seat layout is locked while this bus is under review.' : 'Could not save the layout. Please try again.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _syncCapacity() async {
    setState(() => _saving = true);
    try {
      final n = await ref.read(supabaseProvider).rpc('sync_bus_capacity_from_layout', params: {'p_bus_id': widget.bus['id']});
      widget.bus['total_seats'] = n; // reflect locally; providers refresh on return
      ref.invalidate(busProvider(widget.bus['id'] as String));
      ref.invalidate(busesProvider(widget.operatorId));
    } catch (e) {
      setState(() => _error = 'Could not update the capacity. Save the layout first.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Color _color(BuildContext context, SeatKind k) => switch (k) {
        SeatKind.bookable => AppColors.success.withValues(alpha: 0.25),
        SeatKind.unavailable => Colors.grey.shade400,
        SeatKind.reserved => AppColors.warning.withValues(alpha: 0.35),
        SeatKind.crew => AppColors.primary.withValues(alpha: 0.35),
        SeatKind.other => Colors.blueGrey.shade200,
      };

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(busLayoutProvider(widget.bus['id'] as String));

    return Scaffold(
      appBar: AppBar(title: const Text('Seat layout')),
      body: SafeArea(
        child: async.when(
          data: (data) {
            _load(data);
            return _body(context);
          },
          loading: () => const AppLoadingState(),
          error: (e, _) => AppErrorState(
            message: 'Could not load the seat layout.',
            onRetry: () => ref.invalidate(busLayoutProvider(widget.bus['id'] as String)),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final theme = Theme.of(context);
    final validation = validateLayout(config: _config, cells: _cells, busType: _busType, capacity: _capacity);
    final codes = generateSeatCodes(_config, _cells);
    final bookable = bookableCount(_cells);
    final multiDeckAllowed = _seating != 'seater';

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        if (!_editable)
          const Padding(
            padding: EdgeInsets.only(bottom: AppSpacing.sm),
            child: Text('This bus is under review or approved, so the layout is read-only.'),
          ),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Layout size', style: theme.textTheme.titleSmall),
              const SizedBox(height: AppSpacing.xs),
              Wrap(
                spacing: AppSpacing.md,
                runSpacing: AppSpacing.xs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _Stepper(label: 'Rows', value: _config.rows, min: 1, max: 40, enabled: _editable, onChanged: (v) => _resize(rows: v)),
                  _Stepper(label: 'Columns', value: _config.cols, min: 1, max: 8, enabled: _editable, onChanged: (v) => _resize(cols: v)),
                  if (multiDeckAllowed)
                    SegmentedButton<int>(
                      segments: const [ButtonSegment(value: 1, label: Text('1 deck')), ButtonSegment(value: 2, label: Text('2 decks'))],
                      selected: {_config.decks},
                      onSelectionChanged: _editable ? (s) => _resize(decks: s.first) : null,
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Text('Aisle columns (tap to toggle)', style: theme.textTheme.bodySmall),
              Wrap(
                spacing: AppSpacing.xs,
                children: [
                  for (var c = 1; c <= _config.cols; c++)
                    FilterChip(
                      label: Text('$c'),
                      selected: _config.aisleCols.contains(c),
                      onSelected: _editable ? (_) => _toggleAisle(c) : null,
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.xs),
              Row(
                children: [
                  const Text('Numbering: '),
                  DropdownButton<Numbering>(
                    value: _config.numbering,
                    items: const [
                      DropdownMenuItem(value: Numbering.rowLetter, child: Text('Row + letter (1A, 1B)')),
                      DropdownMenuItem(value: Numbering.sequential, child: Text('Sequential (1, 2, 3)')),
                    ],
                    onChanged: _editable ? (v) => setState(() { _config = _config.copyWith(numbering: v); _dirty = true; }) : null,
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        if (_editable) ...[
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: [
              for (final t in _Tool.values)
                if (!(t == _Tool.sleeper && _seating != 'semi_sleeper'))
                  ChoiceChip(
                    label: Text(switch (t) {
                      _Tool.seat => _seating == 'sleeper' ? 'Sleeper berth' : 'Seat',
                      _Tool.sleeper => 'Sleeper berth',
                      _Tool.premium => 'Premium (fare category)',
                      _Tool.unavailable => 'Not available',
                      _Tool.reserved => 'Reserved',
                      _Tool.crew => 'Driver / crew',
                      _Tool.other => 'Other',
                      _Tool.erase => 'Erase',
                    }),
                    selected: _tool == t,
                    onSelected: (_) => setState(() => _tool = t),
                  ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Row(
            children: [
              TextButton.icon(
                onPressed: _saving
                    ? null
                    : () => setState(() {
                          _dirty = true;
                          _cells = autoFillSeats(_config, count: _capacity, sleeper: _seating == 'sleeper');
                        }),
                icon: const Icon(Icons.auto_fix_high),
                label: Text('Auto-fill $_capacity seats'),
              ),
              TextButton.icon(
                onPressed: _saving ? null : () => setState(() { _cells = {}; _dirty = true; }),
                icon: const Icon(Icons.clear_all),
                label: const Text('Clear'),
              ),
            ],
          ),
        ],
        if (_config.decks == 2)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
            child: SegmentedButton<int>(
              segments: const [ButtonSegment(value: 1, label: Text('Lower deck')), ButtonSegment(value: 2, label: Text('Upper deck'))],
              selected: {_deck},
              onSelectionChanged: (s) => setState(() => _deck = s.first),
            ),
          ),
        const SizedBox(height: AppSpacing.xs),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Column(
            children: [
              for (var r = 1; r <= _config.rows; r++)
                Row(
                  children: [
                    for (var c = 1; c <= _config.cols; c++)
                      if (_config.aisleCols.contains(c))
                        const SizedBox(width: 24, height: 44)
                      else
                        Builder(builder: (context) {
                          final cell = _cells[(_deck, r, c)];
                          return GestureDetector(
                            onTap: () => _paint(r, c),
                            child: Container(
                              width: 44,
                              height: 44,
                              margin: const EdgeInsets.all(2),
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: cell == null ? Colors.transparent : _color(context, cell.kind),
                                border: Border.all(
                                  color: cell?.category == 'premium' ? AppColors.primary : Theme.of(context).dividerColor,
                                  width: cell?.category == 'premium' ? 2.5 : 1,
                                ),
                                borderRadius: BorderRadius.circular(cell?.sleeper == true ? 4 : 10),
                              ),
                              child: cell == null
                                  ? null
                                  : Text(codes[(_deck, r, c)] ?? '', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                            ),
                          );
                        }),
                  ],
                ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: AppSpacing.sm,
          children: [
            for (final k in SeatKind.values)
              Chip(
                visualDensity: VisualDensity.compact,
                avatar: CircleAvatar(backgroundColor: _color(context, k), radius: 6),
                label: Text(k.label, style: theme.textTheme.bodySmall),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Bookable seats: $bookable · Capacity: $_capacity', style: theme.textTheme.titleSmall),
              const SizedBox(height: AppSpacing.xs),
              if (validation.valid && _serverErrors.isEmpty)
                const Text('Layout looks valid.')
              else
                for (final e in {...validation.errors, ..._serverErrors})
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.error_outline, size: 16, color: theme.colorScheme.error),
                        const SizedBox(width: 4),
                        Expanded(child: Text(e, style: TextStyle(color: theme.colorScheme.error))),
                      ],
                    ),
                  ),
              for (final w in validation.warnings)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Row(children: [
                    const Icon(Icons.info_outline, size: 16),
                    const SizedBox(width: 4),
                    Expanded(child: Text(w)),
                  ]),
                ),
              if (_editable && bookable != _capacity && bookable > 0 && !_dirty)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.xs),
                  child: TextButton(onPressed: _saving ? null : _syncCapacity, child: Text('Set bus capacity to $bookable')),
                ),
              if (_dirty)
                const Padding(padding: EdgeInsets.only(top: AppSpacing.xs), child: Text('Unsaved changes')),
            ],
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
        ],
        if (_editable) ...[
          const SizedBox(height: AppSpacing.md),
          AppButton(label: 'Save layout', expand: true, loading: _saving, onPressed: (_saving || !_dirty) ? null : _save),
          AppButton(
            label: 'Save & continue later',
            variant: AppButtonVariant.ghost,
            expand: true,
            onPressed: _saving ? null : () async {
              if (_dirty) await _save();
              if (context.mounted) Navigator.of(context).pop();
            },
          ),
        ],
      ],
    );
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({required this.label, required this.value, required this.min, required this.max, required this.enabled, required this.onChanged});

  final String label;
  final int value;
  final int min;
  final int max;
  final bool enabled;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label: '),
        IconButton(visualDensity: VisualDensity.compact, onPressed: (enabled && value > min) ? () => onChanged(value - 1) : null, icon: const Icon(Icons.remove_circle_outline)),
        Text('$value'),
        IconButton(visualDensity: VisualDensity.compact, onPressed: (enabled && value < max) ? () => onChanged(value + 1) : null, icon: const Icon(Icons.add_circle_outline)),
      ],
    );
  }
}
