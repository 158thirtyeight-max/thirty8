/// Pure helpers for the bus schedule (Stage F). Mirrors the checks in
/// `validate_bus_schedule` / `save_bus_schedule` and the day selection of
/// `generate_bus_trips` in SQL.
library;

const cutoffPresets = <int>[0, 15, 30, 60, 120, 180, 360, 720, 1440];
const boardingCutoffPresets = <int>[0, 5, 10, 15, 30, 45, 60];

String describeMinutesBefore(int minutes) {
  if (minutes == 0) return 'At departure';
  if (minutes % 1440 == 0) return '${minutes ~/ 1440} day${minutes == 1440 ? '' : 's'} before';
  if (minutes % 60 == 0) return '${minutes ~/ 60} hour${minutes == 60 ? '' : 's'} before';
  return '$minutes min before';
}

List<String> validateSchedule({
  required int? departureMin,
  required Set<int> days,
  required int openDaysBefore,
  required int bookingCutoffMin,
  required int boardingCutoffMin,
}) {
  final errors = <String>[];
  if (departureMin == null) errors.add('Choose the departure time');
  if (days.isEmpty) errors.add('Select at least one operating day');
  if (days.any((d) => d < 1 || d > 7)) errors.add('Operating days must be Monday to Sunday');
  if (openDaysBefore < 1 || openDaysBefore > 365) errors.add('Bookings must open between 1 and 365 days ahead');
  if (bookingCutoffMin < 0 || bookingCutoffMin > 10080) errors.add('Booking cut-off must be between 0 minutes and 7 days');
  if (boardingCutoffMin < 0 || boardingCutoffMin > 10080) errors.add('Boarding cut-off must be between 0 minutes and 7 days');
  if (boardingCutoffMin > bookingCutoffMin + 1440) {
    errors.add('The boarding cut-off is unreasonably earlier than the booking cut-off');
  }
  return errors;
}

/// Dates in [from, to] (inclusive, date-only) whose ISO weekday is in [days].
List<DateTime> tripDatesInRange(DateTime from, DateTime to, Set<int> days) {
  final start = DateTime(from.year, from.month, from.day);
  final end = DateTime(to.year, to.month, to.day);
  final out = <DateTime>[];
  for (var d = start; !d.isAfter(end); d = DateTime(d.year, d.month, d.day + 1)) {
    if (days.contains(d.weekday)) out.add(d); // DateTime.weekday is ISO: Mon=1 .. Sun=7
  }
  return out;
}
