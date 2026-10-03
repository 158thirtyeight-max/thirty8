import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';

import 'numbering.dart';
import 'seat_layout_model.dart';
import 'validation.dart';

Color _kindColor(SeatKind k) => switch (k) {
      SeatKind.passenger => AppColors.primary,
      SeatKind.reserved => AppColors.warning,
      SeatKind.crew => AppColors.info,
      SeatKind.unavailable => AppColors.disabledDark,
    };

String kindLabel(SeatKind k) => switch (k) {
      SeatKind.passenger => 'Passenger',
      SeatKind.reserved => 'Reserved',
      SeatKind.crew => 'Crew',
      SeatKind.unavailable => 'Unavailable',
    };

String numberingLabel(NumberingMethod m) => switch (m) {
      NumberingMethod.rowWise => 'Row-wise',
      NumberingMethod.columnWise => 'Column-wise',
      NumberingMethod.alphabetical => 'Alphabetical',
      NumberingMethod.manual => 'Manual',
    };

Color _muted(BuildContext c) => Theme.of(c).brightness == Brightness.dark ? AppColors.textSecondaryDark : AppColors.textSecondary;
Color _text(BuildContext c) => Theme.of(c).brightness == Brightness.dark ? AppColors.textPrimaryDark : AppColors.textPrimary;

Widget _heading(BuildContext c, String title, String sub) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: AppTypography.h3(_text(c))),
        const SizedBox(height: AppSpacing.xs),
        Text(sub, style: AppTypography.body(_muted(c))),
        const SizedBox(height: AppSpacing.md),
      ],
    );

/// A single seat tile — used by the editor and the mini previews.
class SeatTile extends StatelessWidget {
  const SeatTile({super.key, required this.kind, required this.label, this.size = 52, this.sleeper = false, this.onTap});

  final SeatKind kind;
  final String label;
  final double size;
  final bool sleeper;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = _kindColor(kind);
    final unavailable = kind == SeatKind.unavailable;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: sleeper ? size * 1.5 : size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color.withValues(alpha: unavailable ? 0.25 : 0.2),
          border: Border.all(color: color, width: 1.5),
          borderRadius: AppRadius.smRadius,
        ),
        child: Text(
          label,
          style: AppTypography.label(_text(context)).copyWith(
            fontSize: size >= 44 ? 13 : 9,
            decoration: unavailable ? TextDecoration.lineThrough : null,
          ),
        ),
      ),
    );
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({required this.label, required this.value, required this.onChanged, this.min = 0, this.max = 99});

  final String label;
  final int value;
  final ValueChanged<int> onChanged;
  final int min;
  final int max;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: AppTypography.bodyLarge(_text(context))),
              ],
            ),
          ),
          IconButton.outlined(
            onPressed: value > min ? () => onChanged(value - 1) : null,
            icon: const Icon(Icons.remove),
            tooltip: 'Decrease $label',
          ),
          SizedBox(width: 48, child: Center(child: Text('$value', style: AppTypography.h4(_text(context))))),
          IconButton.outlined(
            onPressed: value < max ? () => onChanged(value + 1) : null,
            icon: const Icon(Icons.add),
            tooltip: 'Increase $label',
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- Step 1

class CapacityStep extends StatelessWidget {
  const CapacityStep({super.key, required this.draft, required this.onChanged});

  final SeatLayoutDraft draft;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final error = validateCapacity(draft);
    void set(void Function() f) {
      f();
      onChanged();
    }

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        _heading(context, 'Bus capacity', 'Set total seats, then set aside any that are not for passengers.'),
        AppCard(
          child: Column(
            children: [
              _Stepper(label: 'Total capacity', value: draft.capacity, min: 1, max: maxCapacity, onChanged: (v) => set(() => draft.capacity = v)),
              const Divider(),
              _Stepper(label: 'Reserved seats', value: draft.reserved, onChanged: (v) => set(() => draft.reserved = v), max: draft.capacity),
              _Stepper(label: 'Crew seats', value: draft.crew, onChanged: (v) => set(() => draft.crew = v), max: draft.capacity),
              _Stepper(label: 'Unavailable seats', value: draft.unavailable, onChanged: (v) => set(() => draft.unavailable = v), max: draft.capacity),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        AppCard(
          variant: AppCardVariant.elevated,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Live summary', style: AppTypography.label(_muted(context))),
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: [
                  _SummaryChip(label: 'Passenger', value: draft.passenger, color: _kindColor(SeatKind.passenger)),
                  _SummaryChip(label: 'Reserved', value: draft.reserved, color: _kindColor(SeatKind.reserved)),
                  _SummaryChip(label: 'Crew', value: draft.crew, color: _kindColor(SeatKind.crew)),
                  _SummaryChip(label: 'Unavail.', value: draft.unavailable, color: _kindColor(SeatKind.unavailable)),
                ],
              ),
              if (error != null) ...[
                const SizedBox(height: AppSpacing.sm),
                Text(error, style: AppTypography.body(AppColors.error)),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _SummaryChip extends StatelessWidget {
  const _SummaryChip({required this.label, required this.value, required this.color});
  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(
          children: [
            Text('$value', style: AppTypography.h3(color)),
            Text(label, style: AppTypography.caption(_muted(context))),
          ],
        ),
      );
}

// ---------------------------------------------------------------- Step 2

class ArrangementStep extends StatelessWidget {
  const ArrangementStep({super.key, required this.draft, required this.onChanged});

  final SeatLayoutDraft draft;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        _heading(context, 'Seat arrangement', 'Pick how seats sit either side of the aisle.'),
        for (final a in SeatArrangement.values)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: AppRadius.lgRadius,
                border: Border.all(color: a == draft.arrangement ? primary : Colors.transparent, width: 2),
              ),
              child: AppCard(
                variant: AppCardVariant.interactive,
                onTap: () {
                  draft.arrangement = a;
                  onChanged();
                },
                child: Row(
                  children: [
                    _ArrangementPreview(arrangement: a),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Text(a.label, style: AppTypography.h4(_text(context))),
                    ),
                    if (a == draft.arrangement) Icon(Icons.check_circle, color: primary) else Icon(Icons.circle_outlined, color: _muted(context)),
                  ],
                ),
              ),
            ),
          ),
        const SizedBox(height: AppSpacing.md),
        Text('Driver position', style: AppTypography.h4(_text(context))),
        const SizedBox(height: AppSpacing.sm),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: true, label: Text('Left'), icon: Icon(Icons.keyboard_arrow_left)),
            ButtonSegment(value: false, label: Text('Right'), icon: Icon(Icons.keyboard_arrow_right)),
          ],
          selected: {draft.driverLeft},
          onSelectionChanged: (s) {
            draft.driverLeft = s.first;
            onChanged();
          },
        ),
      ],
    );
  }
}

class _ArrangementPreview extends StatelessWidget {
  const _ArrangementPreview({required this.arrangement});
  final SeatArrangement arrangement;

  @override
  Widget build(BuildContext context) {
    Widget block(int n) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [for (var i = 0; i < n; i++) const Padding(padding: EdgeInsets.all(2), child: SeatTile(kind: SeatKind.passenger, label: '', size: 18))],
        );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var r = 0; r < 2; r++)
          Row(mainAxisSize: MainAxisSize.min, children: [block(arrangement.left), const SizedBox(width: 12), block(arrangement.right)]),
      ],
    );
  }
}

// ---------------------------------------------------------------- Step 3

class SeatMapStep extends StatefulWidget {
  const SeatMapStep({super.key, required this.draft, required this.onChanged});

  final SeatLayoutDraft draft;
  final VoidCallback onChanged;

  @override
  State<SeatMapStep> createState() => _SeatMapStepState();
}

class _SeatMapStepState extends State<SeatMapStep> {
  double _zoom = 1.0;

  SeatLayoutDraft get d => widget.draft;

  void _change(void Function() f) {
    setState(f);
    widget.onChanged();
  }

  Future<void> _editSeat(int row, int col) async {
    final key = cellKey(row, col);
    final labels = computeLabels(d.cells, d.numbering, manualLabels: d.manualLabels);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final cell = d.cells[key];
          if (cell == null) return const SizedBox.shrink();
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.md),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Seat ${labels[key]} · row $row, column $col', style: AppTypography.h4(_text(ctx))),
                  const SizedBox(height: AppSpacing.md),
                  Wrap(
                    spacing: AppSpacing.sm,
                    children: [
                      for (final k in SeatKind.values)
                        AppChip(
                          label: kindLabel(k),
                          selected: cell.kind == k,
                          onTap: () {
                            _change(() => d.cells[key] = cell.copyWith(kind: k));
                            setSheet(() {});
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: false, label: Text('Seater')),
                      ButtonSegment(value: true, label: Text('Sleeper')),
                    ],
                    selected: {cell.sleeper},
                    onSelectionChanged: (s) {
                      _change(() => d.cells[key] = cell.copyWith(sleeper: s.first));
                      setSheet(() {});
                    },
                  ),
                  const SizedBox(height: AppSpacing.md),
                  AppButton(
                    label: 'Remove seat',
                    variant: AppButtonVariant.destructive,
                    icon: Icons.delete_outline,
                    expand: true,
                    onPressed: () {
                      _change(() => d.cells.remove(key));
                      Navigator.of(ctx).pop();
                    },
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = 52 * _zoom;
    const gap = 8.0;
    final labels = computeLabels(d.cells, d.numbering, manualLabels: d.manualLabels);
    final muted = _muted(context);

    Widget zoneLabel(String text, {IconData? icon}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) Icon(icon, size: 16, color: muted),
              if (icon != null) const SizedBox(width: 4),
              Text(text, style: AppTypography.caption(muted)),
            ],
          ),
        );

    Widget slot(int r, int c) {
      final key = cellKey(r, c);
      final cell = d.cells[key];
      if (cell == null) {
        return GestureDetector(
          onTap: () => _change(() => d.cells[key] = const SeatCell(kind: SeatKind.passenger)),
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              borderRadius: AppRadius.smRadius,
              border: Border.all(color: muted.withValues(alpha: 0.4)),
            ),
            child: Icon(Icons.add, color: muted, size: 18),
          ),
        );
      }
      return SeatTile(kind: cell.kind, label: labels[key] ?? '', size: size, sleeper: cell.sleeper, onTap: () => _editSeat(r, c));
    }

    final steering = Icon(Icons.radio_button_checked, color: muted);
    final front = Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Column(children: [d.driverLeft ? steering : const Icon(Icons.meeting_room_outlined), Text(d.driverLeft ? 'Driver' : 'Entrance', style: AppTypography.caption(muted))]),
        Column(children: [d.driverLeft ? const Icon(Icons.meeting_room_outlined) : steering, Text(d.driverLeft ? 'Entrance' : 'Driver', style: AppTypography.caption(muted))]),
      ],
    );

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, 0),
          child: Row(
            children: [
              Expanded(child: Text('${d.configured} seats configured', style: AppTypography.h4(_text(context)))),
              IconButton(
                onPressed: _zoom > 0.7 ? () => setState(() => _zoom -= 0.2) : null,
                icon: const Icon(Icons.zoom_out),
                tooltip: 'Zoom out',
              ),
              IconButton(
                onPressed: _zoom < 1.5 ? () => setState(() => _zoom += 0.2) : null,
                icon: const Icon(Icons.zoom_in),
                tooltip: 'Zoom in',
              ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Center(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Container(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  decoration: BoxDecoration(
                    borderRadius: AppRadius.xlRadius,
                    border: Border.all(color: muted.withValues(alpha: 0.5), width: 2),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(width: d.columns * (size + gap) + 28, child: front),
                      zoneLabel('FRONT', icon: Icons.keyboard_double_arrow_up),
                      for (var r = 1; r <= d.rows; r++)
                        Padding(
                          padding: const EdgeInsets.only(bottom: gap),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (var c = 1; c <= d.columns; c++) ...[
                                if (c == d.arrangement.left + 1) SizedBox(width: 28, child: Center(child: Text(r == 1 ? 'aisle' : '', style: AppTypography.caption(muted).copyWith(fontSize: 9)))),
                                Padding(padding: const EdgeInsets.symmetric(horizontal: gap / 2), child: slot(r, c)),
                              ],
                            ],
                          ),
                        ),
                      zoneLabel('REAR', icon: Icons.keyboard_double_arrow_down),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.sm),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  label: Text('Add row'),
                  icon: Icon(Icons.add, size: 18),
                  onPressed: d.rows < 40
                      ? () => _change(() {
                            d.rows += 1;
                            for (var c = 1; c <= d.columns; c++) {
                              d.cells[cellKey(d.rows, c)] = const SeatCell(kind: SeatKind.passenger);
                            }
                          })
                      : null,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: OutlinedButton.icon(
                  label: Text('Remove row'),
                  icon: Icon(Icons.remove, size: 18),
                  onPressed: d.rows > 1
                      ? () => _change(() {
                            for (var c = 1; c <= d.columns; c++) {
                              d.cells.remove(cellKey(d.rows, c));
                            }
                            d.rows -= 1;
                          })
                      : null,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- Step 4

class NumberingStep extends StatelessWidget {
  const NumberingStep({super.key, required this.draft, required this.onChanged});

  final SeatLayoutDraft draft;
  final VoidCallback onChanged;

  Map<String, SeatCell> get _sample {
    final cols = draft.columns;
    return {
      for (var r = 1; r <= 2; r++)
        for (var c = 1; c <= cols; c++) cellKey(r, c): const SeatCell(kind: SeatKind.passenger),
    };
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        _heading(context, 'Seat numbering', 'Labels update instantly. Your seat map is never changed.'),
        for (final m in NumberingMethod.values)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: AppRadius.lgRadius,
                border: Border.all(color: m == draft.numbering ? primary : Colors.transparent, width: 2),
              ),
              child: AppCard(
                variant: AppCardVariant.interactive,
                onTap: () {
                  draft.numbering = m;
                  onChanged();
                },
                child: Row(
                  children: [
                    _NumberingPreview(labels: computeLabels(_sample, m), draft: draft),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(child: Text(numberingLabel(m), style: AppTypography.h4(_text(context)))),
                    if (m == draft.numbering) Icon(Icons.check_circle, color: primary),
                  ],
                ),
              ),
            ),
          ),
        if (draft.numbering == NumberingMethod.manual) ...[
          const SizedBox(height: AppSpacing.md),
          Text('Edit labels', style: AppTypography.h4(_text(context))),
          const SizedBox(height: AppSpacing.sm),
          _ManualEditor(draft: draft, onChanged: onChanged),
        ],
      ],
    );
  }
}

class _NumberingPreview extends StatelessWidget {
  const _NumberingPreview({required this.labels, required this.draft});
  final Map<String, String> labels;
  final SeatLayoutDraft draft;

  @override
  Widget build(BuildContext context) {
    final a = draft.arrangement;
    Widget cell(int r, int c) => Padding(
          padding: const EdgeInsets.all(2),
          child: SeatTile(kind: SeatKind.passenger, label: labels[cellKey(r, c)] ?? '', size: 28),
        );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var r = 1; r <= 2; r++)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var c = 1; c <= a.columns; c++) ...[
                if (c == a.left + 1) const SizedBox(width: 8),
                cell(r, c),
              ],
            ],
          ),
      ],
    );
  }
}

class _ManualEditor extends StatelessWidget {
  const _ManualEditor({required this.draft, required this.onChanged});
  final SeatLayoutDraft draft;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final labels = computeLabels(draft.cells, NumberingMethod.manual, manualLabels: draft.manualLabels);
    final counts = <String, int>{};
    for (final l in labels.values) {
      counts[l] = (counts[l] ?? 0) + 1;
    }
    final keys = draft.cells.keys.toList()
      ..sort((a, b) {
        final pa = a.split(','), pb = b.split(',');
        final r = int.parse(pa[0]).compareTo(int.parse(pb[0]));
        return r != 0 ? r : int.parse(pa[1]).compareTo(int.parse(pb[1]));
      });
    return Column(
      children: [
        for (final k in keys)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: Row(
              children: [
                SizedBox(width: 72, child: Text('Row ${k.split(',')[0]} · ${k.split(',')[1]}', style: AppTypography.caption(_muted(context)))),
                Expanded(
                  child: TextFormField(
                    // Keyed by the stored value so edits elsewhere don't leave stale text.
                    key: ValueKey('$k|${draft.manualLabels[k] ?? ''}'),
                    initialValue: labels[k],
                    decoration: InputDecoration(
                      isDense: true,
                      errorText: (counts[labels[k]] ?? 0) > 1 ? 'Duplicate' : null,
                    ),
                    onChanged: (v) {
                      draft.manualLabels[k] = v.trim();
                    },
                    onFieldSubmitted: (_) => onChanged(),
                    onEditingComplete: onChanged,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------- Step 5

class ReviewStep extends StatelessWidget {
  const ReviewStep({super.key, required this.draft});
  final SeatLayoutDraft draft;

  @override
  Widget build(BuildContext context) {
    final issues = validateLayout(draft);
    Widget row(String l, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Expanded(child: Text(l, style: AppTypography.body(_muted(context)))),
              Text(v, style: AppTypography.bodyLarge(_text(context))),
            ],
          ),
        );
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        _heading(context, 'Review & save', 'Check everything before this layout goes live.'),
        AppCard(
          child: Column(
            children: [
              row('Bus capacity', '${draft.capacity}'),
              row('Passenger seats', '${draft.countKind(SeatKind.passenger)}'),
              row('Reserved seats', '${draft.countKind(SeatKind.reserved)}'),
              row('Crew seats', '${draft.countKind(SeatKind.crew)}'),
              row('Unavailable seats', '${draft.countKind(SeatKind.unavailable)}'),
              row('Total configured', '${draft.configured}'),
              row('Arrangement', draft.arrangement.label),
              row('Numbering', numberingLabel(draft.numbering)),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        if (issues.isEmpty)
          AppCard(
            child: Row(children: [
              const Icon(Icons.check_circle, color: AppColors.success),
              const SizedBox(width: AppSpacing.sm),
              Expanded(child: Text('Configuration is valid', style: AppTypography.body(_text(context)))),
            ]),
          )
        else
          for (final i in issues)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: AppCard(
                child: Row(children: [
                  Icon(i.blocking ? Icons.error : Icons.warning_amber, color: i.blocking ? AppColors.error : AppColors.warning),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(child: Text(i.message, style: AppTypography.body(_text(context)))),
                ]),
              ),
            ),
      ],
    );
  }
}
