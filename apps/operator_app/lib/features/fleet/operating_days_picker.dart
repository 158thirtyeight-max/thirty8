import 'package:flutter/material.dart';

const _dayLabels = {1: 'Mon', 2: 'Tue', 3: 'Wed', 4: 'Thu', 5: 'Fri', 6: 'Sat', 7: 'Sun'};

String describeOperatingDays(Set<int> days) {
  if (days.length == 7) return 'Every day';
  if (days.isEmpty) return 'No days';
  final sorted = days.toList()..sort();
  return sorted.map((d) => _dayLabels[d]).join(', ');
}

/// ISO weekday chips (1 = Monday ... 7 = Sunday), matching bus_services.operating_days.
class OperatingDaysPicker extends StatelessWidget {
  const OperatingDaysPicker({super.key, required this.days, required this.onChanged, this.enabled = true});

  final Set<int> days;
  final ValueChanged<Set<int>> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      children: [
        for (final e in _dayLabels.entries)
          FilterChip(
            label: Text(e.value),
            selected: days.contains(e.key),
            onSelected: enabled
                ? (sel) {
                    final next = {...days};
                    sel ? next.add(e.key) : next.remove(e.key);
                    onChanged(next);
                  }
                : null,
          ),
      ],
    );
  }
}
