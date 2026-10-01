import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';

import 'seat_layout_model.dart';

Color positionColor(PositionType t) => switch (t) {
      PositionType.passenger => AppColors.success,
      PositionType.ladies => const Color(0xFFEC4899),
      PositionType.accessible => AppColors.info,
      PositionType.crew || PositionType.driver || PositionType.conductor => AppColors.primary,
      PositionType.unavailable => AppColors.textTertiary,
    };

IconData? positionIcon(PositionType t) => switch (t) {
      PositionType.passenger => null,
      PositionType.ladies => Icons.woman,
      PositionType.accessible => Icons.accessible,
      PositionType.crew => Icons.groups_outlined,
      PositionType.driver => Icons.drive_eta,
      PositionType.conductor => Icons.badge_outlined,
      PositionType.unavailable => Icons.block,
    };

const double _seatSize = 44;
const double _seatMargin = 2;
const double _aisleWidth = 32;

double _colWidth(bool aisle) => aisle ? _aisleWidth : _seatSize + _seatMargin * 2;

/// Which tap action the bus drawing currently offers.
enum CanvasMode { seats, aisle, types, number }

/// The bus seen from above: FRONT / DRIVER at the top, seats and the aisle
/// as the operator drew them, REAR at the bottom.
class BusCanvas extends StatelessWidget {
  const BusCanvas({
    super.key,
    required this.config,
    required this.cells,
    required this.codes,
    required this.deck,
    required this.mode,
    required this.editable,
    required this.onCell,
    required this.onToggleAisle,
  });

  final LayoutConfig config;
  final Map<CellKey, SeatCell> cells;
  final Map<CellKey, String> codes;
  final int deck;
  final CanvasMode mode;
  final bool editable;
  final void Function(int row, int col) onCell;
  final ValueChanged<int> onToggleAisle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final width = [for (var c = 1; c <= config.cols; c++) _colWidth(config.aisleCols.contains(c))].fold<double>(0, (a, b) => a + b);

    Widget banner(String text, IconData icon) => Container(
          width: width,
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            color: AppColors.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: AppColors.primary),
              const SizedBox(width: 6),
              Text(text, style: theme.textTheme.labelMedium?.copyWith(color: AppColors.primary, fontWeight: FontWeight.w700, letterSpacing: 1)),
            ],
          ),
        );

    return Center(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.sm),
          decoration: BoxDecoration(
            border: Border.all(color: theme.dividerColor, width: 2),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(36), bottom: Radius.circular(12)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              banner('FRONT / DRIVER', Icons.arrow_downward),
              const SizedBox(height: AppSpacing.xs),
              if (mode == CanvasMode.aisle) _aisleStrip(context),
              for (var r = 1; r <= config.rows; r++) _row(context, r),
              const SizedBox(height: AppSpacing.xs),
              banner('REAR', Icons.keyboard_double_arrow_down),
            ],
          ),
        ),
      ),
    );
  }

  Widget _aisleStrip(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Row(
        children: [
          for (var c = 1; c <= config.cols; c++)
            () {
              final aisle = config.aisleCols.contains(c);
              return SizedBox(
                width: _colWidth(aisle),
                child: Tooltip(
                  message: aisle ? 'Aisle — tap to make this a seat column' : 'Seat column — tap to make this the aisle',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: editable ? () => onToggleAisle(c) : null,
                    child: Container(
                      height: 36,
                      margin: const EdgeInsets.symmetric(horizontal: 2),
                      decoration: BoxDecoration(
                        color: aisle ? AppColors.warning.withValues(alpha: 0.25) : Colors.transparent,
                        border: Border.all(color: aisle ? AppColors.warning : theme.dividerColor),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      alignment: Alignment.center,
                      child: aisle
                          ? const Text('│', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18))
                          : Icon(Icons.event_seat_outlined, size: 18, color: theme.hintColor),
                    ),
                  ),
                ),
              );
            }(),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, int r) {
    final theme = Theme.of(context);
    final cab = config.cabRow && r == 1 && deck == 1;
    return Container(
      decoration: cab
          ? BoxDecoration(color: AppColors.primary.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(8))
          : null,
      child: Row(
        children: [
          for (var c = 1; c <= config.cols; c++)
            if (config.aisleCols.contains(c))
              SizedBox(
                width: _aisleWidth,
                height: _seatSize + _seatMargin * 2,
                child: Center(child: Container(width: 1.5, color: theme.dividerColor)),
              )
            else
              _tile(context, r, c),
        ],
      ),
    );
  }

  Widget _tile(BuildContext context, int r, int c) {
    final theme = Theme.of(context);
    final cell = cells[(deck, r, c)];
    final type = cell?.type;
    final color = type == null ? null : positionColor(type);
    final icon = type == null ? null : positionIcon(type);
    final code = codes[(deck, r, c)] ?? '';
    final manualPending = cell != null && cell.isNumbered && config.numbering == Numbering.manual && isPlaceholderCode(cell.number);
    final tappable = editable &&
        switch (mode) {
          CanvasMode.seats => true,
          CanvasMode.types => cell != null,
          CanvasMode.number => cell != null && cell.isNumbered,
          CanvasMode.aisle => false,
        };

    Widget label() {
      if (cell == null) {
        return mode == CanvasMode.seats && editable ? Icon(Icons.add, size: 16, color: theme.hintColor) : const SizedBox.shrink();
      }
      if (manualPending) return Text('?', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: color));
      final text = Text(code, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700));
      if (!cell.isNumbered) return Icon(icon, size: 20, color: color);
      if (icon == null) return text;
      return Column(mainAxisSize: MainAxisSize.min, children: [Icon(icon, size: 12, color: color), text]);
    }

    return GestureDetector(
      onTap: tappable ? () => onCell(r, c) : null,
      child: Container(
        width: _seatSize,
        height: _seatSize,
        margin: const EdgeInsets.all(_seatMargin),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color?.withValues(alpha: type == PositionType.unavailable ? 0.25 : 0.2),
          border: Border.all(
            color: cell?.category == 'premium' ? AppColors.primary : (color ?? theme.dividerColor).withValues(alpha: cell == null ? 1 : 0.7),
            width: cell?.category == 'premium' ? 2.5 : 1,
          ),
          borderRadius: BorderRadius.circular(cell?.sleeper == true ? 4 : 10),
        ),
        child: label(),
      ),
    );
  }
}

/// A tiny schematic of seats: each entry is a label, '' for an empty seat
/// box, or '|' for the aisle.
class MiniGrid extends StatelessWidget {
  const MiniGrid({super.key, required this.rows, this.sleeper = false});

  final List<List<String>> rows;
  final bool sleeper;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 1.5),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final t in row)
                  if (t == '|')
                    Container(width: 1.5, height: 18, margin: const EdgeInsets.symmetric(horizontal: 4), color: theme.hintColor)
                  else
                    Container(
                      width: t.length > 2 ? 24 : 20,
                      height: 18,
                      margin: const EdgeInsets.symmetric(horizontal: 1.5),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: AppColors.success.withValues(alpha: 0.2),
                        border: Border.all(color: AppColors.success.withValues(alpha: 0.7)),
                        borderRadius: BorderRadius.circular(sleeper ? 2 : 5),
                      ),
                      child: t.isEmpty ? null : Text(t, style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w700)),
                    ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Selectable card with a clearly highlighted selected state.
class ChoiceCard extends StatelessWidget {
  const ChoiceCard({super.key, required this.selected, required this.onTap, required this.child, this.width});

  final bool selected;
  final VoidCallback? onTap;
  final Widget child;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: width,
      child: Material(
        color: selected ? AppColors.primary.withValues(alpha: 0.08) : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: selected ? AppColors.primary : theme.dividerColor, width: selected ? 2 : 1),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.sm),
            child: Stack(
              children: [
                Padding(padding: const EdgeInsets.only(right: 18), child: child),
                if (selected)
                  const Positioned(top: 0, right: 0, child: Icon(Icons.check_circle, size: 18, color: AppColors.primary)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Example grids shown on the numbering cards.
List<List<String>> numberingPreview(Numbering n) => switch (n) {
      Numbering.rowWise => [
          ['1', '2', '|', '3', '4'],
          ['5', '6', '|', '7', '8'],
        ],
      Numbering.columnWise => [
          ['1', '3', '|', '5', '7'],
          ['2', '4', '|', '6', '8'],
        ],
      Numbering.alphabetical => [
          ['A1', 'A2', '|', 'A3', 'A4'],
          ['B1', 'B2', '|', 'B3', 'B4'],
        ],
      Numbering.manual => [
          ['3', '', '|', '1', ''],
          ['', '2', '|', '', ''],
        ],
      Numbering.rowLetter => [
          ['1A', '1B', '|', '1C', '1D'],
        ],
    };

List<List<String>> presetPreview(AislePreset p) {
  final row = [
    for (var i = 0; i < p.left; i++) '',
    if (p.left > 0 && p.right > 0) '|',
    for (var i = 0; i < p.right; i++) '',
  ];
  return [row, row];
}
