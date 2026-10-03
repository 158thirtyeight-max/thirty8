import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'route_model.dart';
import 'stop_schedule.dart';

/// A horizontal time ruler for choosing when the bus reaches a stop. The ruler always spans the whole
/// journey window (departure to destination arrival), so it fits any screen width: it shows hour
/// markers with readable labels, shades the range the stop may use and has a draggable thumb that
/// snaps to [snap] minutes. The value is an offset in minutes after the journey starts, so overnight
/// journeys stay chronological.
class TimeRuler extends StatelessWidget {
  const TimeRuler({
    super.key,
    required this.startMin,
    required this.duration,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.enabled = true,
    this.snap = snapMinutes,
  });

  /// Departure clock time at the starting point (minutes since midnight).
  final int startMin;

  /// Journey length in minutes (the ruler's full width).
  final int duration;

  /// Selected offset (minutes after the journey starts).
  final int value;

  /// Permitted range for the selection (offsets).
  final int min;
  final int max;
  final ValueChanged<int> onChanged;
  final bool enabled;
  final int snap;

  static const double _pad = 18;

  String _label(int offset) {
    final d = (startMin + offset) ~/ minutesPerDay;
    return '${formatClock((startMin + offset) % minutesPerDay)}${d > 0 ? ' +${d}d' : ''}';
  }

  int _clamp(int v) => v.clamp(min, math.max(min, max));

  void _pick(double dx, double width) {
    if (!enabled) return;
    final usable = width - 2 * _pad;
    final raw = ((dx - _pad) / usable * duration).clamp(0, duration.toDouble());
    final snapped = _clamp((raw / snap).round() * snap);
    if (snapped != value) onChanged(snapped);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      slider: true,
      enabled: enabled,
      label: 'Arrival time',
      value: _label(value),
      increasedValue: _label(_clamp(value + snap)),
      decreasedValue: _label(_clamp(value - snap)),
      onIncrease: enabled ? () => onChanged(_clamp(value + snap)) : null,
      onDecrease: enabled ? () => onChanged(_clamp(value - snap)) : null,
      child: LayoutBuilder(builder: (context, c) {
        final width = c.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => _pick(d.localPosition.dx, width),
          onHorizontalDragStart: (d) => _pick(d.localPosition.dx, width),
          onHorizontalDragUpdate: (d) => _pick(d.localPosition.dx, width),
          child: SizedBox(
            height: 78,
            width: width,
            child: CustomPaint(
              painter: _RulerPainter(
                startMin: startMin,
                duration: duration,
                value: value,
                min: min,
                max: max,
                primary: theme.colorScheme.primary,
                onSurface: theme.colorScheme.onSurface,
                muted: theme.colorScheme.outlineVariant,
                surface: theme.colorScheme.surface,
                labelStyle: theme.textTheme.labelSmall ?? const TextStyle(fontSize: 11),
                enabled: enabled,
              ),
            ),
          ),
        );
      }),
    );
  }
}

class _RulerPainter extends CustomPainter {
  _RulerPainter({
    required this.startMin,
    required this.duration,
    required this.value,
    required this.min,
    required this.max,
    required this.primary,
    required this.onSurface,
    required this.muted,
    required this.surface,
    required this.labelStyle,
    required this.enabled,
  });

  final int startMin;
  final int duration;
  final int value;
  final int min;
  final int max;
  final Color primary;
  final Color onSurface;
  final Color muted;
  final Color surface;
  final TextStyle labelStyle;
  final bool enabled;

  @override
  void paint(Canvas canvas, Size size) {
    const pad = TimeRuler._pad;
    final usable = size.width - 2 * pad;
    double x(int offset) => pad + offset / duration * usable;
    const baseY = 34.0;

    // whole journey window
    final track = Paint()
      ..color = muted
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(x(0), baseY), Offset(x(duration), baseY), track);
    // permitted range
    final allowed = Paint()
      ..color = primary.withValues(alpha: enabled ? 0.45 : 0.2)
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(x(min), baseY), Offset(x(math.max(min, max)), baseY), allowed);

    // hour markers; label spacing adapts to the width so labels never overlap
    final pxPerHour = usable / (duration / 60);
    final labelEvery = math.max(1, (52 / pxPerHour).ceil());
    final tick = Paint()
      ..color = onSurface.withValues(alpha: 0.5)
      ..strokeWidth = 1;
    final firstHour = ((startMin + 59) ~/ 60) * 60; // first full hour at or after departure
    var hourIndex = 0;
    for (var clock = firstHour; clock - startMin <= duration; clock += 60, hourIndex++) {
      final offset = clock - startMin;
      final labelled = hourIndex % labelEvery == 0;
      canvas.drawLine(Offset(x(offset), baseY + 6), Offset(x(offset), baseY + (labelled ? 15 : 10)), tick);
      if (labelled) {
        final tp = TextPainter(
          text: TextSpan(text: formatClock(clock % minutesPerDay), style: labelStyle.copyWith(color: onSurface)),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(x(offset) - tp.width / 2, baseY + 17));
      }
    }

    // end labels: departure and arrival
    void edge(String text, double dx, {required bool left}) {
      final tp = TextPainter(
        text: TextSpan(text: text, style: labelStyle.copyWith(color: primary, fontWeight: FontWeight.w700)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(left ? math.max(0, dx - tp.width / 2) : math.min(size.width - tp.width, dx - tp.width / 2), 0));
    }

    edge('Departs ${formatClock(startMin)}', x(0), left: true);
    final endClock = (startMin + duration) % minutesPerDay;
    edge('Arrives ${formatClock(endClock)}', x(duration), left: false);

    // thumb
    final tx = x(value.clamp(0, duration));
    canvas.drawCircle(Offset(tx, baseY), 15, Paint()..color = primary.withValues(alpha: 0.18));
    canvas.drawCircle(Offset(tx, baseY), 10, Paint()..color = enabled ? primary : muted);
    canvas.drawCircle(Offset(tx, baseY), 10, Paint()
      ..color = surface
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(_RulerPainter old) =>
      old.value != value || old.min != min || old.max != max || old.duration != duration || old.startMin != startMin || old.enabled != enabled;
}
