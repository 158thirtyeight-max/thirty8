import 'numbering.dart';
import 'seat_layout_model.dart';

const maxCapacity = 80;

class LayoutIssue {
  const LayoutIssue(this.message, {this.blocking = true});
  final String message;
  final bool blocking;
}

String? validateCapacity(SeatLayoutDraft d) {
  if (d.capacity < 1 || d.capacity > maxCapacity) return 'Capacity must be between 1 and $maxCapacity';
  if (d.reserved < 0 || d.crew < 0 || d.unavailable < 0) return 'Seat counts cannot be negative';
  if (d.passenger < 1) return 'At least one passenger seat is required';
  return null;
}

List<LayoutIssue> validateLayout(SeatLayoutDraft d) {
  final issues = <LayoutIssue>[];
  final capacityError = validateCapacity(d);
  if (capacityError != null) issues.add(LayoutIssue(capacityError));

  if (d.configured != d.capacity) {
    issues.add(LayoutIssue('Seat map has ${d.configured} seats but bus capacity is ${d.capacity}', blocking: false));
  }
  if (d.countKind(SeatKind.passenger) == 0) issues.add(const LayoutIssue('No passenger seats configured'));

  final labels = computeLabels(d.cells, d.numbering, manualLabels: d.manualLabels);
  final seen = <String, int>{};
  for (final l in labels.values) {
    seen[l] = (seen[l] ?? 0) + 1;
  }
  final dupes = seen.entries.where((e) => e.value > 1).map((e) => e.key).toList()..sort();
  if (dupes.isNotEmpty) issues.add(LayoutIssue('Duplicate seat labels: ${dupes.join(', ')}'));
  return issues;
}
