import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/supabase_providers.dart';
import 'fleet_providers.dart';
import 'seat_layout_model.dart';
import 'seat_layout_widgets.dart';

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

/// Result of the seat bottom sheet: a replacement cell, or removal.
class _SeatEdit {
  const _SeatEdit.set(this.cell) : remove = false;
  const _SeatEdit.remove()
      : cell = null,
        remove = true;
  final SeatCell? cell;
  final bool remove;
}

/// Stage C — visual seat layout. The operator sees the bus from above (FRONT /
/// DRIVER at the top), builds it from the declared capacity and a layout
/// style, adjusts the aisle by tapping columns, picks a numbering method, and
/// sets each position's type. Structural rules are shown live; the server
/// re-validates on save, submit, approval and activation. Only Passenger
/// seats are ever offered to customers.
class StageSeatLayoutScreen extends ConsumerStatefulWidget {
  const StageSeatLayoutScreen({super.key, required this.operatorId, required this.bus});

  final String operatorId;
  final Map<String, dynamic> bus;

  @override
  ConsumerState<StageSeatLayoutScreen> createState() => _StageSeatLayoutScreenState();
}

class _StageSeatLayoutScreenState extends ConsumerState<StageSeatLayoutScreen> {
  LayoutConfig _config = const LayoutConfig(rows: 1, cols: 5, decks: 1, aisleCols: {3});
  Map<CellKey, SeatCell> _cells = {};
  CanvasMode _mode = CanvasMode.types;
  int _deck = 1;
  late int _capacity = widget.bus['total_seats'] as int;
  late AislePreset _preset = _seating == 'sleeper' ? sleeperPresets.first : seaterPresets.first;
  int _decksChoice = 1;
  bool _cabRow = true;
  bool _driverRight = true;
  bool _loaded = false;
  bool _saving = false;
  bool _dirty = false;
  String? _error;
  List<String> _serverErrors = const [];

  String get _busType => widget.bus['bus_type'] as String;
  String get _seating => seatingOf(_busType);
  bool get _manual => _config.numbering == Numbering.manual;

  bool get _editable {
    final lifecycle = widget.bus['lifecycle_status'] as String?;
    return widget.bus['is_legacy'] == true || lifecycle == 'draft' || lifecycle == 'changes_requested';
  }

  void _load(Map<String, dynamic> data) {
    if (_loaded) return;
    _loaded = true;
    final layout = data['layout'] as Map<String, dynamic>?;
    final seats = List<Map<String, dynamic>>.from(data['seats'] as List);
    if (layout == null || seats.isEmpty) {
      _mode = CanvasMode.types;
      return;
    }

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
    } else {
      _config = cfg;
      _cells = {
        for (final s in seats) (s['deck'] as int, s['row_no'] as int, s['col_no'] as int): seatCellFromRow(s),
      };
      // Auto-numbered codes are derived from position; only manual numbers are stored on the cell.
      if (cfg.numbering != Numbering.manual) {
        _cells = {for (final e in _cells.entries) e.key: e.value.copyWith(number: null)};
      }
    }
    _decksChoice = _config.decks;
    _cabRow = _config.cabRow;
    if (_config.aisleCols.length == 1) {
      final a = _config.aisleCols.first;
      for (final p in [...seaterPresets, ...sleeperPresets]) {
        if (p.left == a - 1 && p.right == _config.cols - a) _preset = p;
      }
    }
    if (_manual) _mode = CanvasMode.number;
  }

  // ---- editing ---------------------------------------------------------

  void _touch(void Function() change) => setState(() {
        _dirty = true;
        change();
      });

  Future<bool> _confirm(String title, String body, {String action = 'Continue'}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(action)),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _build() async {
    if (_cells.isNotEmpty &&
        !await _confirm('Rebuild the layout?', 'This replaces every seat, aisle and seat type you have set so far.', action: 'Rebuild')) {
      return;
    }
    final built = buildLayout(
      preset: _preset,
      capacity: _capacity,
      decks: _seating == 'seater' ? 1 : _decksChoice,
      sleeper: _seating == 'sleeper',
      cabRow: _cabRow,
      driverOnRight: _driverRight,
      numbering: _config.numbering,
    );
    _touch(() {
      _config = built.config;
      _cells = built.cells;
      _deck = 1;
      _mode = _manual ? CanvasMode.number : CanvasMode.types;
    });
  }

  void _setNumbering(Numbering n) {
    _touch(() {
      _config = _config.copyWith(numbering: n);
      if (n == Numbering.manual) {
        _mode = CanvasMode.number;
      } else if (_mode == CanvasMode.number) {
        _mode = CanvasMode.types;
      }
    });
  }

  void _addRow() {
    if (_config.rows >= 40) return;
    _touch(() => _config = _config.copyWith(rows: _config.rows + 1));
  }

  void _removeRow() {
    if (_config.rows <= 1) return;
    final rows = _config.rows - 1;
    _touch(() {
      _config = _config.copyWith(rows: rows);
      _cells = {for (final e in _cells.entries) if (e.key.$2 <= rows) e.key: e.value};
    });
  }

  void _addCol() {
    if (_config.cols >= 8) return;
    _touch(() => _config = _config.copyWith(cols: _config.cols + 1));
  }

  void _removeCol() {
    if (_config.cols <= 1) return;
    final cols = _config.cols - 1;
    _touch(() {
      _config = _config.copyWith(cols: cols, aisleCols: _config.aisleCols.where((c) => c <= cols).toSet());
      _cells = {for (final e in _cells.entries) if (e.key.$3 <= cols) e.key: e.value};
    });
  }

  Future<void> _toggleAisle(int col) async {
    final making = !_config.aisleCols.contains(col);
    if (making && _cells.keys.any((k) => k.$3 == col) && !await _confirm('Make this column the aisle?', 'Seats in this column will be removed.', action: 'Make aisle')) {
      return;
    }
    _touch(() {
      final a = {..._config.aisleCols};
      if (!a.add(col)) a.remove(col);
      _config = _config.copyWith(aisleCols: a);
      _cells = {for (final e in _cells.entries) if (!a.contains(e.key.$3)) e.key: e.value};
    });
  }

  Future<void> _onCell(int row, int col) async {
    if (!_editable || _saving) return;
    final key = (_deck, row, col);
    final cell = _cells[key];
    switch (_mode) {
      case CanvasMode.seats:
        _touch(() {
          if (cell == null) {
            _cells = {..._cells, key: SeatCell(kind: SeatKind.bookable, sleeper: _seating == 'sleeper')};
          } else {
            _cells = {..._cells}..remove(key);
          }
        });
      case CanvasMode.types:
        if (cell != null) await _openSeatSheet(key, cell);
      case CanvasMode.number:
        if (cell == null || !cell.isNumbered) return;
        if (isPlaceholderCode(cell.number)) {
          final used = {for (final c in _cells.values) if (c.number != null) c.number};
          var n = 1;
          while (used.contains('$n')) {
            n++;
          }
          _touch(() => _cells = {..._cells, key: cell.copyWith(number: '$n')});
        } else {
          await _editNumber(key, cell);
        }
      case CanvasMode.aisle:
        break;
    }
  }

  Future<void> _openSeatSheet(CellKey key, SeatCell cell) async {
    final code = generateSeatCodes(_config, _cells)[key] ?? '';
    final result = await showModalBottomSheet<_SeatEdit>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _SeatSheet(title: cell.isNumbered && code.isNotEmpty ? 'Seat $code' : cell.type.label, cell: cell, seating: _seating),
    );
    if (result == null) return;
    _touch(() {
      if (result.remove) {
        _cells = {..._cells}..remove(key);
      } else {
        _cells = {..._cells, key: result.cell!};
      }
    });
  }

  Future<void> _editNumber(CellKey key, SeatCell cell) async {
    final taken = {
      for (final e in _cells.entries)
        if (e.key != key && e.value.number != null) e.value.number!.toUpperCase(),
    };
    final ctrl = TextEditingController(text: cell.number);
    String? error;
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Seat number'),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')), LengthLimitingTextInputFormatter(4)],
            decoration: InputDecoration(labelText: 'Number', errorText: error),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(ctx, ''), child: const Text('Clear number')),
            FilledButton(
              onPressed: () {
                final v = ctrl.text.trim().toUpperCase();
                if (!isValidManualNumber(v)) {
                  setLocal(() => error = 'Use up to 4 letters or digits');
                } else if (taken.contains(v)) {
                  setLocal(() => error = 'Seat $v already has this number');
                } else {
                  Navigator.pop(ctx, v);
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    ctrl.dispose();
    if (result == null) return;
    _touch(() => _cells = {..._cells, key: cell.copyWith(number: result.isEmpty ? null : result)});
  }

  Future<void> _resetNumbers() async {
    if (!await _confirm('Clear all seat numbers?', 'Every seat will be un-numbered so you can number them again from 1.', action: 'Clear all')) return;
    _touch(() => _cells = {for (final e in _cells.entries) e.key: e.value.copyWith(number: null)});
  }

  Future<void> _editCapacity() async {
    final ctrl = TextEditingController(text: '$_capacity');
    String? error;
    final value = await showDialog<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Bus capacity'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Total positions on the bus: passenger seats, reserved seats, crew and driver.'),
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: ctrl,
                autofocus: true,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(3)],
                decoration: InputDecoration(labelText: 'Capacity', errorText: error),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                final v = int.tryParse(ctrl.text.trim());
                final stats = layoutStats(_cells);
                if (v == null || v < 1 || v > 80) {
                  setLocal(() => error = 'Enter a number from 1 to 80');
                } else if (v < stats.bookable) {
                  setLocal(() => error = 'Your layout already has ${stats.bookable} passenger seats');
                } else {
                  Navigator.pop(ctx, v);
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    ctrl.dispose();
    if (value != null && value != _capacity) await _saveCapacity(value);
  }

  Future<void> _saveCapacity(int value) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(supabaseProvider).from('buses').update({'total_seats': value}).eq('id', widget.bus['id'] as String);
      widget.bus['total_seats'] = value; // reflect locally; providers refresh on return
      ref.invalidate(busProvider(widget.bus['id'] as String));
      ref.invalidate(busesProvider(widget.operatorId));
      if (mounted) setState(() => _capacity = value);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not update the capacity. It may be locked while the bus is under review.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
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

  // ---- build -----------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(busLayoutProvider(widget.bus['id'] as String));

    return PopScope(
      canPop: !_dirty || !_editable,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final leave = await _confirm('Discard unsaved changes?', 'Your seat layout changes have not been saved.', action: 'Discard');
        if (leave && context.mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
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
      ),
    );
  }

  Widget _section(BuildContext context, int n, String title, {String? subtitle, required Widget child}) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(radius: 11, backgroundColor: AppColors.primary, child: Text('$n', style: const TextStyle(color: Colors.white, fontSize: 12))),
                const SizedBox(width: AppSpacing.sm),
                Expanded(child: Text(title, style: theme.textTheme.titleSmall)),
              ],
            ),
            if (subtitle != null) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(subtitle, style: theme.textTheme.bodySmall),
            ],
            const SizedBox(height: AppSpacing.sm),
            child,
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final theme = Theme.of(context);
    final stats = layoutStats(_cells);
    final validation = validateLayout(config: _config, cells: _cells, busType: _busType, capacity: _capacity);
    final codes = generateSeatCodes(_config, _cells);
    final errors = {...validation.errors, ..._serverErrors};

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        if (!_editable)
          const Padding(
            padding: EdgeInsets.only(bottom: AppSpacing.sm),
            child: Text('This bus is under review or approved, so the layout is read-only.'),
          ),
        _section(
          context,
          1,
          'Bus capacity',
          subtitle: 'Total positions on the bus: passenger seats, reserved seats, crew and driver.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('$_capacity', style: theme.textTheme.headlineSmall),
                  const SizedBox(width: AppSpacing.xs),
                  const Text('positions'),
                  const Spacer(),
                  if (_editable) OutlinedButton.icon(onPressed: _saving ? null : _editCapacity, icon: const Icon(Icons.edit_outlined, size: 18), label: const Text('Edit')),
                ],
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Passenger ${stats.bookable} · Reserved ${stats.reserved} · Crew/driver ${stats.crew} · Total configured ${stats.configured}',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
        if (_editable) _styleCard(context),
        _busCard(context, codes),
        if (_editable) _numberingCard(context, stats),
        _reviewCard(context, stats, validation, errors),
        if (_error != null) ...[
          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          const SizedBox(height: AppSpacing.sm),
        ],
        if (_editable) ...[
          AppButton(label: 'Save layout', expand: true, loading: _saving, onPressed: (_saving || !_dirty) ? null : _save),
          AppButton(
            label: 'Save & continue later',
            variant: AppButtonVariant.ghost,
            expand: true,
            onPressed: _saving
                ? null
                : () async {
                    if (_dirty) await _save();
                    if (context.mounted && !_dirty) Navigator.of(context).pop();
                  },
          ),
        ],
      ],
    );
  }

  // 2. layout style ------------------------------------------------------
  Widget _styleCard(BuildContext context) {
    final theme = Theme.of(context);
    final presets = _seating == 'sleeper' ? sleeperPresets : seaterPresets;
    final sleeper = _seating == 'sleeper';
    final subtitle = switch (_seating) {
      'sleeper' => 'Sleeper berths either side of the aisle. Choose single or double deck.',
      'semi_sleeper' => 'Seats either side of the aisle. You can switch individual positions to sleeper berths later.',
      _ => 'How many seats are on each side of the aisle?',
    };
    return _section(
      context,
      2,
      'Choose layout style',
      subtitle: subtitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              for (final p in presets)
                ChoiceCard(
                  selected: _preset.left == p.left && _preset.right == p.right,
                  onTap: () => setState(() => _preset = p),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      MiniGrid(rows: presetPreview(p), sleeper: sleeper),
                      const SizedBox(height: 4),
                      Text(p.label, style: theme.textTheme.labelMedium),
                    ],
                  ),
                ),
            ],
          ),
          if (_seating != 'seater') ...[
            const SizedBox(height: AppSpacing.sm),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 1, label: Text('Single deck')),
                ButtonSegment(value: 2, label: Text('Lower + upper deck')),
              ],
              selected: {_decksChoice},
              onSelectionChanged: (s) => setState(() => _decksChoice = s.first),
            ),
          ],
          const SizedBox(height: AppSpacing.xs),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Driver cab at the front'),
            subtitle: const Text('Adds a front row with the driver position'),
            value: _cabRow,
            onChanged: (v) => setState(() => _cabRow = v),
          ),
          if (_cabRow)
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Driver on left'), icon: Icon(Icons.west, size: 16)),
                ButtonSegment(value: true, label: Text('Driver on right'), icon: Icon(Icons.east, size: 16)),
              ],
              selected: {_driverRight},
              onSelectionChanged: (s) => setState(() => _driverRight = s.first),
            ),
          const SizedBox(height: AppSpacing.sm),
          AppButton(
            label: _cells.isEmpty ? 'Build layout for $_capacity positions' : 'Rebuild layout',
            icon: Icons.auto_fix_high,
            variant: _cells.isEmpty ? AppButtonVariant.primary : AppButtonVariant.outline,
            expand: true,
            onPressed: _saving ? null : _build,
          ),
        ],
      ),
    );
  }

  // 3. the bus -----------------------------------------------------------
  Widget _busCard(BuildContext context, Map<CellKey, String> codes) {
    final theme = Theme.of(context);
    final modes = <(CanvasMode, IconData, String)>[
      (CanvasMode.types, Icons.event_seat, 'Seat types'),
      (CanvasMode.seats, Icons.add_circle_outline, 'Add / remove seats'),
      (CanvasMode.aisle, Icons.swap_horiz, 'Aisle'),
      if (_manual) (CanvasMode.number, Icons.pin_outlined, 'Number seats'),
    ];
    final hint = switch (_mode) {
      CanvasMode.types => 'Tap a seat to make it Passenger, Ladies Reserved, Accessible, Crew, Driver, Conductor or Unavailable.',
      CanvasMode.seats => 'Tap an empty spot to add a seat. Tap a seat to remove it.',
      CanvasMode.aisle => 'Tap a column header to make it the aisle (shown as │) or turn it back into seats.',
      CanvasMode.number => 'Tap seats in the order you choose. Each gets the next free number and keeps it. Tap a numbered seat to change or clear it.',
    };

    return _section(
      context,
      3,
      'Your bus',
      subtitle: 'Seen from above. The front of the bus and the driver are at the top.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_editable) ...[
            Wrap(
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.xs,
              children: [
                for (final m in modes)
                  ChoiceChip(
                    avatar: Icon(m.$2, size: 16),
                    label: Text(m.$3),
                    selected: _mode == m.$1,
                    onSelected: (_) => setState(() => _mode = m.$1),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(hint, style: theme.textTheme.bodySmall),
            const SizedBox(height: AppSpacing.sm),
          ],
          if (_config.decks == 2)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: SegmentedButton<int>(
                segments: const [ButtonSegment(value: 1, label: Text('Lower deck')), ButtonSegment(value: 2, label: Text('Upper deck'))],
                selected: {_deck},
                onSelectionChanged: (s) => setState(() => _deck = s.first),
              ),
            ),
          if (_cells.isEmpty && _editable)
            Container(
              padding: const EdgeInsets.all(AppSpacing.md),
              margin: const EdgeInsets.only(bottom: AppSpacing.sm),
              decoration: BoxDecoration(color: AppColors.primary.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(12)),
              child: const Text('No seats yet. Pick a layout style above and tap “Build layout”, or switch to “Add / remove seats” and draw it yourself.'),
            ),
          BusCanvas(
            config: _config,
            cells: _cells,
            codes: codes,
            deck: _deck,
            mode: _mode,
            editable: _editable && !_saving,
            onCell: _onCell,
            onToggleAisle: _toggleAisle,
          ),
          if (_editable) ...[
            const SizedBox(height: AppSpacing.xs),
            Wrap(
              spacing: AppSpacing.xs,
              children: [
                TextButton.icon(onPressed: _config.rows < 40 ? _addRow : null, icon: const Icon(Icons.add, size: 16), label: const Text('Add row')),
                TextButton.icon(onPressed: _config.rows > 1 ? _removeRow : null, icon: const Icon(Icons.remove, size: 16), label: const Text('Remove last row')),
                if (_mode == CanvasMode.aisle) ...[
                  TextButton.icon(onPressed: _config.cols < 8 ? _addCol : null, icon: const Icon(Icons.add, size: 16), label: const Text('Add column')),
                  TextButton.icon(onPressed: _config.cols > 1 ? _removeCol : null, icon: const Icon(Icons.remove, size: 16), label: const Text('Remove column')),
                ],
              ],
            ),
          ],
          const SizedBox(height: AppSpacing.xs),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: 2,
            children: [
              for (final t in PositionType.values)
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(positionIcon(t) ?? Icons.square_rounded, size: 14, color: positionColor(t)),
                  const SizedBox(width: 4),
                  Text(t.label, style: theme.textTheme.bodySmall),
                ]),
            ],
          ),
        ],
      ),
    );
  }

  // 4. numbering ---------------------------------------------------------
  Widget _numberingCard(BuildContext context, LayoutStats stats) {
    final theme = Theme.of(context);
    const methods = [
      (Numbering.rowWise, 'Row-wise', 'Left to right, row by row'),
      (Numbering.columnWise, 'Column-wise', 'Down each column'),
      (Numbering.alphabetical, 'Alphabetical', 'Row letter + seat'),
      (Numbering.manual, 'Manual', 'You number each seat'),
    ];
    final numbered = _cells.values.where((c) => c.isNumbered).length;
    final done = numbered - unnumberedCount(_config, _cells);
    return _section(
      context,
      4,
      'Choose numbering method',
      subtitle: 'Numbers apply to passenger and reserved seats. Driver, crew and unavailable positions are not numbered.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(builder: (context, c) {
            final w = (c.maxWidth - AppSpacing.sm) / 2;
            return Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                for (final m in methods)
                  ChoiceCard(
                    width: w,
                    selected: _config.numbering == m.$1,
                    onTap: _saving ? null : () => _setNumbering(m.$1),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(m.$2, style: theme.textTheme.titleSmall),
                        Text(m.$3, style: theme.textTheme.bodySmall),
                        const SizedBox(height: 6),
                        FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: MiniGrid(rows: numberingPreview(m.$1))),
                      ],
                    ),
                  ),
              ],
            );
          }),
          if (_config.numbering == Numbering.rowLetter)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Text('This layout uses the older “1A” numbering. Pick a method above to change it.', style: theme.textTheme.bodySmall),
            ),
          if (_manual) ...[
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Icon(done == numbered && numbered > 0 ? Icons.check_circle : Icons.pin_outlined, size: 18, color: done == numbered && numbered > 0 ? AppColors.success : null),
                const SizedBox(width: 6),
                Expanded(child: Text('$done of $numbered seats numbered')),
                TextButton(onPressed: () => setState(() => _mode = CanvasMode.number), child: const Text('Number seats')),
                TextButton(onPressed: done == 0 ? null : _resetNumbers, child: const Text('Clear all')),
              ],
            ),
            Text('Numbers never change on their own — moving or adding seats will not renumber the others.', style: theme.textTheme.bodySmall),
          ],
        ],
      ),
    );
  }

  // 5. review ------------------------------------------------------------
  Widget _reviewCard(BuildContext context, LayoutStats stats, LayoutValidation validation, Set<String> errors) {
    final theme = Theme.of(context);
    final numbered = _cells.values.where((c) => c.isNumbered).length;
    final done = numbered - unnumberedCount(_config, _cells);
    final ladies = _cells.values.where((c) => c.type == PositionType.ladies).length;
    final accessible = _cells.values.where((c) => c.type == PositionType.accessible).length;
    final methodLabel = switch (_config.numbering) {
      Numbering.rowWise => 'Row-wise',
      Numbering.columnWise => 'Column-wise',
      Numbering.alphabetical => 'Alphabetical',
      Numbering.manual => 'Manual ($done of $numbered numbered)',
      Numbering.rowLetter => 'Row + letter (1A, 1B)',
    };

    Widget line(String label, String value, {bool bold = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            Expanded(child: Text(label)),
            Text(value, style: bold ? const TextStyle(fontWeight: FontWeight.w700) : null),
          ]),
        );

    final mismatch = stats.configured != _capacity && _cells.isNotEmpty;
    return _section(
      context,
      5,
      'Review',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          line('Declared bus capacity', '$_capacity'),
          line('Passenger / bookable seats', '${stats.bookable}'),
          line('Reserved seats', '${stats.reserved}${stats.reserved > 0 ? '  (Ladies $ladies · Accessible $accessible)' : ''}'),
          line('Crew / driver positions', '${stats.crew}'),
          line('Unavailable positions', '${stats.unavailable}'),
          const Divider(),
          line('Total configured', '${stats.configured} of $_capacity', bold: true),
          line('Seat numbering', methodLabel),
          const SizedBox(height: AppSpacing.xs),
          Text('Customers can only book Passenger seats (${stats.bookable}). Reserved, crew and unavailable positions are never sold.', style: theme.textTheme.bodySmall),
          if (mismatch)
            Container(
              margin: const EdgeInsets.only(top: AppSpacing.sm),
              padding: const EdgeInsets.all(AppSpacing.sm),
              decoration: BoxDecoration(color: AppColors.warning.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    const Icon(Icons.warning_amber_rounded, size: 18, color: AppColors.warning),
                    const SizedBox(width: 6),
                    Expanded(child: Text('Your layout has ${stats.configured} positions but the declared capacity is $_capacity.')),
                  ]),
                  if (_editable)
                    Wrap(spacing: AppSpacing.xs, children: [
                      TextButton(onPressed: _saving ? null : _editCapacity, child: const Text('Edit capacity')),
                      if (stats.configured >= 1 && stats.configured <= 80 && stats.configured >= stats.bookable)
                        TextButton(onPressed: _saving ? null : () => _saveCapacity(stats.configured), child: Text('Set capacity to ${stats.configured}')),
                    ]),
                ],
              ),
            ),
          const SizedBox(height: AppSpacing.sm),
          if (errors.isEmpty && validation.warnings.isEmpty && !_dirty)
            const Row(children: [Icon(Icons.check_circle, size: 18, color: AppColors.success), SizedBox(width: 6), Text('Layout looks good.')])
          else ...[
            for (final e in errors)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(Icons.error_outline, size: 16, color: theme.colorScheme.error),
                  const SizedBox(width: 4),
                  Expanded(child: Text(e, style: TextStyle(color: theme.colorScheme.error))),
                ]),
              ),
            for (final w in validation.warnings.where((w) => !w.contains('declared bus capacity')))
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(children: [const Icon(Icons.info_outline, size: 16), const SizedBox(width: 4), Expanded(child: Text(w))]),
              ),
          ],
          if (errors.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Text('Fix these before the bus can be submitted.', style: theme.textTheme.bodySmall),
            ),
          if (_dirty) const Padding(padding: EdgeInsets.only(top: AppSpacing.xs), child: Text('Unsaved changes')),
        ],
      ),
    );
  }
}

/// Bottom sheet for one position: pick its type (applies immediately).
class _SeatSheet extends StatelessWidget {
  const _SeatSheet({required this.title, required this.cell, required this.seating});

  final String title;
  final SeatCell cell;
  final String seating;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            for (final t in PositionType.values)
              ListTile(
                contentPadding: EdgeInsets.zero,
                selected: cell.type == t,
                selectedTileColor: positionColor(t).withValues(alpha: 0.12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                leading: CircleAvatar(
                  radius: 16,
                  backgroundColor: positionColor(t).withValues(alpha: 0.2),
                  child: Icon(positionIcon(t) ?? Icons.event_seat, size: 18, color: positionColor(t)),
                ),
                title: Text(t.label),
                subtitle: Text(t.hint),
                trailing: cell.type == t ? const Icon(Icons.check, color: AppColors.primary) : null,
                onTap: () => Navigator.pop(context, _SeatEdit.set(cell.withType(t))),
              ),
            if (cell.type == PositionType.passenger) ...[
              const Divider(),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Premium seat'),
                subtitle: const Text('Can be priced higher in the fares step'),
                value: cell.category == 'premium',
                onChanged: (v) => Navigator.pop(context, _SeatEdit.set(cell.copyWith(category: v ? 'premium' : null))),
              ),
            ],
            if (seating == 'semi_sleeper' && cell.kind != SeatKind.crew) ...[
              const SizedBox(height: AppSpacing.xs),
              SegmentedButton<bool>(
                segments: const [ButtonSegment(value: false, label: Text('Seat')), ButtonSegment(value: true, label: Text('Sleeper berth'))],
                selected: {cell.sleeper},
                onSelectionChanged: (s) => Navigator.pop(context, _SeatEdit.set(cell.copyWith(sleeper: s.first))),
              ),
            ],
            const SizedBox(height: AppSpacing.sm),
            TextButton.icon(
              onPressed: () => Navigator.pop(context, const _SeatEdit.remove()),
              icon: const Icon(Icons.delete_outline),
              label: const Text('Remove this position'),
            ),
          ],
        ),
      ),
    );
  }
}
