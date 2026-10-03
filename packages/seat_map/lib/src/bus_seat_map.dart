import 'dart:math' as math;

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';

import 'models.dart';

/// Status colours. Colour is never the only signal: every non-available state also
/// carries an icon (see [seatStatusIcon]) and a text label in the legend / semantics.
Color seatStatusColor(SeatStatus s) => switch (s) {
      SeatStatus.available => AppColors.success,
      SeatStatus.held => AppColors.warning,
      SeatStatus.booked => AppColors.primary,
      SeatStatus.boarded => AppColors.info,
      SeatStatus.blocked => AppColors.textTertiary,
      SeatStatus.cancelled => AppColors.error,
    };

IconData? seatStatusIcon(SeatStatus s) => switch (s) {
      SeatStatus.available => null,
      SeatStatus.held => Icons.hourglass_top,
      SeatStatus.booked => Icons.person,
      SeatStatus.boarded => Icons.check,
      SeatStatus.blocked => Icons.block,
      SeatStatus.cancelled => Icons.close,
    };

/// A bus drawn from its real configuration: actual seat codes and positions, aisle
/// gaps, one or two decks. Never assumes a 2+2 arrangement.
class BusSeatMap extends StatefulWidget {
  const BusSeatMap({
    super.key,
    required this.layout,
    required this.seats,
    this.onSeatTap,
    this.selectedSeatIds = const {},
    this.dimAvailable = false,
    this.initialDeck = 1,
  });

  final SeatLayoutConfig layout;
  final List<MapSeat> seats;

  /// Called for every tappable seat; the screen decides what a tap means.
  final void Function(MapSeat seat)? onSeatTap;
  final Set<String> selectedSeatIds;

  /// True while availability cannot be verified (channel down / stale): available seats are
  /// shown faded so nobody mistakes them for confirmed-free.
  final bool dimAvailable;
  final int initialDeck;

  @override
  State<BusSeatMap> createState() => _BusSeatMapState();
}

class _BusSeatMapState extends State<BusSeatMap> {
  late int _deck = widget.initialDeck;

  static const double _aisleWidth = 20;
  static const double _gap = 6;

  @override
  Widget build(BuildContext context) {
    final seats = widget.seats;
    if (seats.isEmpty) {
      return const AppEmptyState(message: 'No seats to show.', icon: Icons.event_seat_outlined);
    }
    final decks = ({for (final s in seats) s.deck}.toList()..sort());
    final deck = decks.contains(_deck) ? _deck : decks.first;
    final deckSeats = [for (final s in seats) if (s.deck == deck) s];

    final rows = math.max(widget.layout.rows, deckSeats.map((s) => s.row).fold(0, math.max));
    final cols = math.max(widget.layout.cols, deckSeats.map((s) => s.col).fold(0, math.max));
    final aisles = {for (final c in widget.layout.aisleCols) if (c >= 1 && c <= cols) c};
    final byPos = {for (final s in deckSeats) (s.row, s.col): s};

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (decks.length > 1)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: SegmentedButton<int>(
              segments: [for (final d in decks) ButtonSegment(value: d, label: Text(decks.length == 2 ? (d == decks.first ? 'Lower deck' : 'Upper deck') : 'Deck $d'))],
              selected: {deck},
              onSelectionChanged: (v) => setState(() => _deck = v.first),
            ),
          ),
        LayoutBuilder(builder: (context, c) {
          final seatCols = cols - aisles.length;
          final usable = c.maxWidth - aisles.length * _aisleWidth - (cols - 1) * _gap - 24;
          final cell = seatCols <= 0 ? 44.0 : (usable / seatCols).clamp(34.0, 56.0).toDouble();
          return Container(
            padding: const EdgeInsets.all(AppSpacing.sm),
            decoration: BoxDecoration(
              border: Border.all(color: Theme.of(context).dividerColor),
              borderRadius: AppRadius.lgRadius,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text('FRONT', style: Theme.of(context).textTheme.labelSmall),
                    const SizedBox(width: 6),
                    const Icon(Icons.airline_seat_recline_extra, size: 18),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                for (var r = 1; r <= rows; r++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: _gap),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (var col = 1; col <= cols; col++) ...[
                          if (col > 1) const SizedBox(width: _gap),
                          if (aisles.contains(col))
                            const SizedBox(width: _aisleWidth)
                          else if (byPos[(r, col)] != null)
                            _SeatCell(
                              seat: byPos[(r, col)]!,
                              size: cell,
                              selected: widget.selectedSeatIds.contains(byPos[(r, col)]!.seatId),
                              dim: widget.dimAvailable && byPos[(r, col)]!.status == SeatStatus.available,
                              onTap: widget.onSeatTap,
                            )
                          else
                            SizedBox(width: cell),
                        ],
                      ],
                    ),
                  ),
              ],
            ),
          );
        }),
      ],
    );
  }
}

class _SeatCell extends StatelessWidget {
  const _SeatCell({required this.seat, required this.size, required this.selected, required this.dim, required this.onTap});

  final MapSeat seat;
  final double size;
  final bool selected;
  final bool dim;
  final void Function(MapSeat seat)? onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.primary : seatStatusColor(seat.status);
    final icon = selected ? Icons.check_circle : seatStatusIcon(seat.status);
    final height = seat.isSleeper ? size * 1.7 : size;
    final label = 'Seat ${seat.code}, ${selected ? 'selected' : seat.status.label}';
    final textColor = Theme.of(context).colorScheme.onSurface;

    final cell = Container(
      width: size,
      height: height,
      decoration: BoxDecoration(
        color: color.withValues(alpha: selected ? 0.35 : 0.16),
        border: Border.all(color: color, width: selected ? 2.5 : 1.4),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Text(seat.code, style: TextStyle(fontSize: size < 40 ? 10 : 12, fontWeight: FontWeight.w600, color: textColor)),
          if (icon != null) Positioned(top: 2, right: 2, child: Icon(icon, size: 12, color: color)),
        ],
      ),
    );

    return Semantics(
      button: onTap != null,
      excludeSemantics: true,
      label: label,
      onTap: onTap == null ? null : () => onTap!(seat),
      child: Opacity(
        opacity: dim ? 0.45 : 1,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap == null ? null : () => onTap!(seat),
          child: cell,
        ),
      ),
    );
  }
}

/// Colour + icon + text for each status, so the map never relies on colour alone.
class SeatStatusLegend extends StatelessWidget {
  const SeatStatusLegend({
    super.key,
    this.statuses = const [SeatStatus.available, SeatStatus.held, SeatStatus.booked, SeatStatus.blocked],
    this.showSelected = false,
  });

  final List<SeatStatus> statuses;
  final bool showSelected;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    Widget item(Color color, IconData? icon, String text) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.16),
                border: Border.all(color: color, width: 1.4),
                borderRadius: BorderRadius.circular(4),
              ),
              child: icon == null ? null : Icon(icon, size: 11, color: color),
            ),
            const SizedBox(width: 6),
            Text(text, style: style),
          ],
        );

    return Wrap(
      spacing: AppSpacing.md,
      runSpacing: AppSpacing.xs,
      children: [
        for (final s in statuses) item(seatStatusColor(s), seatStatusIcon(s), s.label),
        if (showSelected) item(AppColors.primary, Icons.check_circle, 'Selected'),
      ],
    );
  }
}

/// "Synced · 10:42" / "Reconnecting…" / "Offline – last updated 10:41". Tap to refresh.
class SyncStatusChip extends StatelessWidget {
  const SyncStatusChip({super.key, required this.label, required this.verified, required this.onRefresh});

  final String label;
  final bool verified;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final color = verified ? AppColors.success : AppColors.warning;
    return InkWell(
      borderRadius: AppRadius.pillRadius,
      onTap: onRefresh,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(verified ? Icons.sync : Icons.sync_problem, size: 14, color: color),
            const SizedBox(width: 4),
            Flexible(child: Text(label, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color), overflow: TextOverflow.ellipsis)),
            const SizedBox(width: 4),
            Icon(Icons.refresh, size: 14, color: color),
          ],
        ),
      ),
    );
  }
}
