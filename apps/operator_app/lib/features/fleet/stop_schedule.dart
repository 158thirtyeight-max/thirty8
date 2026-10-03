/// Timeline scheduling of a journey. A journey has a start (departure clock time at the origin) and a
/// duration (arrival at the destination = start + duration). Every intermediate stop has an arrival
/// *offset* (minutes after the journey starts, so overnight journeys stay chronological) and a dwell
/// time; its departure is always arrival + dwell. Offsets are what the database stores in
/// `arrival_offset_min` / `departure_offset_min`; the server validates the chronology independently.
library;

import 'route_model.dart';

const snapMinutes = 5;
const dwellChoices = [2, 5, 10, 15];
const defaultDwellMin = 5;
const maxDwellMin = 360;

int snapTo(int minutes, [int step = snapMinutes]) => (minutes / step).round() * step;

/// One chronological problem with a stop.
class ScheduleConflict {
  const ScheduleConflict(this.index, this.message);

  final int index;
  final String message;

  @override
  String toString() => message;
}

String _name(JourneyDraft j, int i) => j.stops[i].name.trim().isEmpty ? 'Stop ${i + 1}' : j.stops[i].name.trim();

extension JourneySchedule on JourneyDraft {
  int get lastIndex => stops.length - 1;

  /// A journey window needs both a departure time and a duration.
  bool get hasWindow => startMin != null && durationMin != null && durationMin! > 0;

  /// Arrival clock time at the destination (minutes since midnight).
  int? get endMin => (startMin == null || durationMin == null) ? null : (startMin! + durationMin!) % minutesPerDay;

  /// Clock time (0..1439) of a journey offset.
  int clockOf(int offset) => ((startMin ?? 0) + offset) % minutesPerDay;

  /// Whole days after the departure day that an offset falls on (0 = same day).
  int dayOf(int offset) => ((startMin ?? 0) + offset) ~/ minutesPerDay;

  /// "07:05", or "02:00 (+1 day)" past midnight.
  String timeLabel(int offset) {
    final d = dayOf(offset);
    return '${formatClock(clockOf(offset))}${d > 0 ? ' (+$d day${d > 1 ? 's' : ''})' : ''}';
  }

  int? arrivalAt(int i) {
    if (i == 0) return 0;
    if (i == lastIndex) return durationMin;
    return stops[i].arrivalOffset;
  }

  int? departureAt(int i) {
    if (i == 0) return 0;
    if (i == lastIndex) return durationMin;
    final a = stops[i].arrivalOffset;
    return a == null ? null : a + stops[i].dwellMin;
  }

  /// Earliest time a stop can be left before the stop at [i] (the nearest scheduled stop before it).
  int _earliestFor(int i) {
    for (var k = i - 1; k >= 0; k--) {
      final d = departureAt(k);
      if (d != null) return d;
    }
    return 0;
  }

  /// Latest arrival of the stop at [i] that still lets the bus reach the next scheduled stop on time.
  int? _latestFor(int i) {
    for (var k = i + 1; k <= lastIndex; k++) {
      final a = arrivalAt(k);
      if (a != null) return a - stops[i].dwellMin;
    }
    return durationMin == null ? null : durationMin! - stops[i].dwellMin;
  }

  /// The permitted arrival range of intermediate stop [i] (offsets), or null when the window is not set.
  ({int min, int max})? arrivalBounds(int i) {
    if (!hasWindow || i <= 0 || i >= lastIndex) return null;
    final lo = _earliestFor(i);
    final hi = _latestFor(i)!;
    return (min: lo, max: hi < lo ? lo : hi);
  }

  /// Sets the departure time at the origin. Stops keep their *clock* time (so they are re-validated
  /// rather than silently moved); the destination arrival clock time is kept too.
  void setStart(int clock) {
    final old = startMin;
    if (old == null) {
      startMin = clock;
    } else if (old != clock) {
      final delta = clock - old;
      final oldDur = durationMin;
      final oldEnd = oldDur == null ? null : (old + oldDur) % minutesPerDay;
      startMin = clock;
      for (var i = 1; i < lastIndex; i++) {
        final s = stops[i];
        if (s.manualTime && s.arrivalOffset != null) s.arrivalOffset = s.arrivalOffset! - delta;
      }
      if (oldDur != null && oldEnd != null) {
        final extra = oldDur <= 0 ? 0 : (oldDur - 1) ~/ minutesPerDay;
        var m = ((oldEnd - clock) % minutesPerDay + minutesPerDay) % minutesPerDay;
        if (m == 0) m = minutesPerDay;
        durationMin = m + extra * minutesPerDay;
      }
    }
    autoSchedule();
  }

  /// Sets the arrival time at the destination (the journey is shorter than 24 hours unless it was
  /// already longer).
  void setEnd(int clock) {
    final start = startMin;
    if (start == null) return;
    final extra = (durationMin == null || durationMin! <= 0) ? 0 : (durationMin! - 1) ~/ minutesPerDay;
    var m = ((clock - start) % minutesPerDay + minutesPerDay) % minutesPerDay;
    if (m == 0) m = minutesPerDay;
    durationMin = m + extra * minutesPerDay;
    autoSchedule();
  }

  /// Gives every stop that has no manually chosen time a reasonable estimated arrival: evenly spread
  /// between the surrounding fixed stops (not forced equal travel intervals overall), snapped to 5
  /// minutes. Manually chosen times are never changed here.
  void autoSchedule() {
    if (!hasWindow) return;
    var i = 1;
    while (i < lastIndex) {
      if (stops[i].manualTime && stops[i].arrivalOffset != null) {
        i++;
        continue;
      }
      var j = i;
      while (j + 1 < lastIndex && !(stops[j + 1].manualTime && stops[j + 1].arrivalOffset != null)) {
        j++;
      }
      final prevEnd = departureAt(i - 1) ?? 0;
      final nextStart = arrivalAt(j + 1) ?? durationMin!;
      final run = [for (var k = i; k <= j; k++) stops[k]];
      final dwellSum = run.fold<int>(0, (a, s) => a + s.dwellMin);
      final gap = ((nextStart - prevEnd - dwellSum) / (run.length + 1)).floor();
      var cursor = prevEnd;
      var remainingDwell = dwellSum;
      for (final s in run) {
        remainingDwell -= s.dwellMin;
        var a = snapTo(cursor + (gap < 0 ? 0 : gap));
        final hi = nextStart - remainingDwell - s.dwellMin;
        if (a > hi) a = hi;
        if (a < cursor) a = cursor;
        s
          ..arrivalOffset = a
          ..manualTime = false;
        cursor = a + s.dwellMin;
      }
      i = j + 1;
    }
  }

  /// Chronological problems of the current schedule, one per affected stop (first problem only).
  List<ScheduleConflict> scheduleConflicts() {
    final out = <ScheduleConflict>[];
    if (!hasWindow) return out;
    final dur = durationMin!;
    for (var i = 1; i < lastIndex; i++) {
      final s = stops[i];
      final a = s.arrivalOffset;
      if (a == null) continue;
      final dep = a + s.dwellMin;
      String? problem;
      if (s.dwellMin < 0 || s.dwellMin > maxDwellMin) {
        problem = 'stop time must be between 0 and 6 hours';
      } else if (a < 0) {
        problem = 'arrives before the journey starts (${timeLabel(0)})';
      } else if (dep > dur) {
        problem = 'is still stopped after the destination arrival (${timeLabel(dur)})';
      } else {
        for (var k = i - 1; k >= 0; k--) {
          final d = departureAt(k);
          if (d != null) {
            if (a < d) problem = 'arrives at ${timeLabel(a)}, before ${_name(this, k)} is left at ${timeLabel(d)}';
            break;
          }
        }
        if (problem == null) {
          for (var k = i + 1; k <= lastIndex; k++) {
            final na = arrivalAt(k);
            if (na != null) {
              if (dep > na) problem = 'leaves at ${timeLabel(dep)}, after ${_name(this, k)} is reached at ${timeLabel(na)}';
              break;
            }
          }
        }
      }
      if (problem != null) out.add(ScheduleConflict(i, '${_name(this, i)} $problem'));
    }
    return out;
  }
}

/// Everything wrong with one journey (locations, permissions, window, chronology). Empty = valid.
List<String> validateJourney(JourneyDraft j) {
  final errors = <String>[];
  final stops = j.stops;
  if (j.sourceId == null || j.destId == null) {
    errors.add('Choose a starting point and a destination');
  } else if (j.sourceId == j.destId) {
    errors.add('Starting point and destination must be different');
  }
  if (j.days.isEmpty) errors.add('Select at least one operating day');
  if (stops.length < 2) return [...errors, 'A route needs at least a starting point and a destination'];
  if (stops.length > 30) errors.add('A route can have at most 30 stops');
  if (!stops.first.isBoarding) errors.add('The starting point must be a boarding point');
  if (!stops.last.isDropping) errors.add('The destination must be a dropping point');
  for (var i = 0; i < stops.length; i++) {
    if (stops[i].cityId == null) errors.add('${_name(j, i)}: choose a location');
    if (!stops[i].isBoarding && !stops[i].isDropping) errors.add('${_name(j, i)}: choose boarding, dropping or both');
  }
  if (stops.every((s) => s.cityId != null)) {
    if (j.sourceId != null && stops.first.cityId != j.sourceId) errors.add('The first stop must be the starting point');
    if (j.destId != null && stops.last.cityId != j.destId) errors.add('The last stop must be the destination');
    final seen = <String>{};
    if (stops.any((s) => !seen.add(s.cityId!))) errors.add('A location can appear only once on a route');
  }
  if (j.startMin == null) errors.add('Set the departure time at the starting point');
  if (j.durationMin == null || j.durationMin! < 1) {
    errors.add('Set the arrival time at the destination');
  } else if (j.durationMin! > 72 * 60) {
    errors.add('Journey duration looks too long (over 72 hours)');
  }
  if (j.hasWindow) {
    for (var i = 1; i < j.lastIndex; i++) {
      if (stops[i].arrivalOffset == null) errors.add('${_name(j, i)}: choose an arrival time');
    }
    errors.addAll(j.scheduleConflicts().map((c) => c.message));
  }
  return errors;
}
