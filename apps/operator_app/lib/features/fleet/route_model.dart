/// Pure model for a bus's route (Stage D): ordered stops with clock times.
/// Clock times are what the operator thinks in; the database stores minute
/// offsets from the origin departure, unwrapped across midnight so overnight
/// journeys stay monotonic. `validateRoute` mirrors `validate_bus_route` in SQL.
library;

import 'stop_schedule.dart';

class RouteStop {
  RouteStop({
    required this.name,
    this.isBoarding = false,
    this.isDropping = false,
    this.arrivalMin,
    this.departureMin,
    this.cityId,
    this.address,
    this.boardingPointId,
    this.droppingPointId,
    this.arrivalOffset,
    this.dwellMin = 5,
    this.manualTime = false,
  });

  String name;
  bool isBoarding;
  bool isDropping;

  /// Minutes since midnight (0-1439), null if not entered yet.
  int? arrivalMin;
  int? departureMin;
  String? cityId;
  String? address;

  /// Ids of the existing point rows, so re-saving keeps booking references.
  String? boardingPointId;
  String? droppingPointId;

  /// Timeline scheduling (route revisions): minutes after the journey starts at which the bus arrives
  /// here, how long it stops, and whether the operator chose the time (true) or it is an automatic
  /// estimate. The departure is always `arrivalOffset + dwellMin`.
  int? arrivalOffset;
  int dwellMin;
  bool manualTime;

  // `cityId` is the stop's location (locations.id) and is required.
}

const minutesPerDay = 1440;

/// Turns the clock times of an ordered stop list into offsets (minutes) from
/// the origin's departure. Each time is placed at the earliest moment that is
/// not before the previous time, so 23:30 -> 01:15 becomes +1h45. Missing
/// times yield null offsets.
List<({int? arrival, int? departure})> computeOffsets(List<RouteStop> stops) {
  final out = <({int? arrival, int? departure})>[];
  if (stops.isEmpty || stops.first.departureMin == null) {
    return [for (final _ in stops) (arrival: null, departure: null)];
  }
  final base = stops.first.departureMin!;
  var cursor = 0; // latest offset placed so far
  int place(int clock) {
    var offset = (clock - base) % minutesPerDay;
    while (offset < cursor) {
      offset += minutesPerDay;
    }
    cursor = offset;
    return offset;
  }

  for (var i = 0; i < stops.length; i++) {
    final s = stops[i];
    int? arr;
    int? dep;
    if (i == 0) {
      arr = 0;
      dep = 0;
      cursor = 0;
    } else {
      if (s.arrivalMin != null) arr = place(s.arrivalMin!);
      if (s.departureMin != null) {
        dep = place(s.departureMin!);
      } else if (i == stops.length - 1) {
        dep = arr; // destination: departure == arrival
      }
    }
    out.add((arrival: arr, departure: dep));
  }
  return out;
}

/// Journey duration = arrival offset at the destination (null if not entered).
int? journeyDurationMin(List<RouteStop> stops) {
  final offsets = computeOffsets(stops);
  return offsets.isEmpty ? null : offsets.last.arrival;
}

int clockFromOffset(int departureMin, int offset) => (departureMin + offset) % minutesPerDay;

String formatClock(int? minutes) {
  if (minutes == null) return '--:--';
  final h = (minutes ~/ 60) % 24;
  final m = minutes % 60;
  return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
}

/// Which day a clock time falls on, relative to the day the bus departs.
String dayTag(int daysAfterDeparture) => daysAfterDeparture <= 0 ? 'Today' : (daysAfterDeparture == 1 ? 'Next Day' : '+$daysAfterDeparture days');

String formatDuration(int? minutes) {
  if (minutes == null) return '—';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return h == 0 ? '${m}m' : (m == 0 ? '${h}h' : '${h}h ${m}m');
}

List<String> validateRoute({
  required String? sourceCityId,
  required String? destinationCityId,
  required List<RouteStop> stops,
  required Set<int> operatingDays,
}) {
  final errors = <String>[];
  if (sourceCityId == null || destinationCityId == null) {
    errors.add('Choose an origin and a destination city');
  } else if (sourceCityId == destinationCityId) {
    errors.add('Origin and destination must be different');
  }
  if (operatingDays.isEmpty) errors.add('Select at least one operating day');
  if (stops.length < 2) {
    errors.add('A route needs at least an origin and a destination stop');
    return errors;
  }
  if (stops.length > 30) errors.add('A route can have at most 30 stops');
  if (!stops.first.isBoarding) errors.add('The origin must be a boarding point');
  if (!stops.last.isDropping) errors.add('The destination must be a dropping point');
  if (!stops.any((s) => s.isBoarding)) errors.add('At least one boarding point is required');
  if (!stops.any((s) => s.isDropping)) errors.add('At least one dropping point is required');

  // Every stop is a location chosen by id; the route starts / ends where it says and each
  // location appears once. Each stop is a pickup, a drop or both.
  for (var i = 0; i < stops.length; i++) {
    if (stops[i].cityId == null) {
      final label = stops[i].name.trim().isEmpty ? 'Stop ${i + 1}' : stops[i].name.trim();
      errors.add('$label: choose a location');
    }
  }
  if (stops.every((s) => s.cityId != null)) {
    if (sourceCityId != null && stops.first.cityId != sourceCityId) errors.add('The first stop must be the origin location');
    if (destinationCityId != null && stops.last.cityId != destinationCityId) errors.add('The last stop must be the destination location');
    final seen = <String>{};
    for (final s in stops) {
      if (!seen.add(s.cityId!)) {
        errors.add('A location can appear only once on a route');
        break;
      }
    }
  }
  for (var i = 0; i < stops.length; i++) {
    if (!stops[i].isBoarding && !stops[i].isDropping) {
      final label = stops[i].name.trim().isEmpty ? 'Stop ${i + 1}' : stops[i].name.trim();
      errors.add('$label: choose pickup, drop or both');
    }
  }

  final blank = stops.where((s) => s.name.trim().isEmpty).length;
  if (blank > 0) errors.add('$blank stop(s) have no name');

  if (stops.first.departureMin == null) errors.add('Enter the departure time from the origin');
  for (var i = 1; i < stops.length; i++) {
    final s = stops[i];
    final label = s.name.trim().isEmpty ? 'Stop ${i + 1}' : s.name.trim();
    if (s.arrivalMin == null) errors.add('$label: arrival time is missing');
    final isLast = i == stops.length - 1;
    if (!isLast && s.departureMin == null) errors.add('$label: departure time is missing');
  }

  if (errors.isEmpty) {
    // With every time present, check ordering after midnight unwrapping.
    final offsets = computeOffsets(stops);
    for (var i = 1; i < stops.length; i++) {
      final o = offsets[i];
      final label = stops[i].name.trim();
      if (o.arrival != null && o.departure != null && o.departure! < o.arrival!) {
        errors.add('$label departs before it arrives');
      }
      if (o.arrival != null && o.departure != null && o.departure! - o.arrival! > 6 * 60) {
        errors.add('$label waits over 6 hours — check the departure time');
      }
      final prev = offsets[i - 1];
      final prevEnd = prev.departure ?? prev.arrival ?? 0;
      if (o.arrival != null && o.arrival! < prevEnd) {
        errors.add('$label is reached before the previous stop is left');
      }
    }
    final duration = journeyDurationMin(stops);
    if (duration == null || duration < 1) errors.add('Estimated journey duration must be greater than zero');
    if (duration != null && duration > 72 * 60) errors.add('Journey duration looks too long (over 72 hours)');
  }
  return errors;
}

/// JSON payload for save_bus_route's p_stops.
List<Map<String, dynamic>> stopsToJson(List<RouteStop> stops) {
  final offsets = computeOffsets(stops);
  return [
    for (var i = 0; i < stops.length; i++)
      {
        'name': stops[i].name.trim(),
        'address': stops[i].address,
        'city_id': stops[i].cityId,
        'is_boarding': stops[i].isBoarding,
        'is_dropping': stops[i].isDropping,
        'arrival_offset_min': offsets[i].arrival,
        'departure_offset_min': offsets[i].departure,
        'boarding_point_id': stops[i].boardingPointId,
        'dropping_point_id': stops[i].droppingPointId,
      },
  ];
}

/// Rebuilds the ordered stop list from stored boarding / dropping point rows
/// (same sequence_no = same stop). Inactive rows are ignored.
List<RouteStop> stopsFromPoints({
  required List<Map<String, dynamic>> boarding,
  required List<Map<String, dynamic>> dropping,
  required int departureMin,
}) {
  final bySeq = <int, RouteStop>{};
  void add(Map<String, dynamic> p, {required bool isBoarding}) {
    if (p['is_active'] == false) return;
    final seq = p['sequence_no'] as int;
    final stop = bySeq.putIfAbsent(seq, () => RouteStop(name: (p['name'] as String?) ?? ''));
    stop.name = (p['name'] as String?) ?? stop.name;
    stop.address ??= p['address'] as String?;
    stop.cityId ??= p['city_id'] as String?;
    final arr = p['arrival_offset_min'] as int?;
    final dep = p['departure_offset_min'] as int?;
    if (arr != null) stop.arrivalMin = clockFromOffset(departureMin, arr);
    if (dep != null) stop.departureMin = clockFromOffset(departureMin, dep);
    if (isBoarding) {
      stop.isBoarding = true;
      stop.boardingPointId = p['id'] as String?;
    } else {
      stop.isDropping = true;
      stop.droppingPointId = p['id'] as String?;
    }
  }

  for (final p in boarding) {
    add(p, isBoarding: true);
  }
  for (final p in dropping) {
    add(p, isBoarding: false);
  }
  final keys = bySeq.keys.toList()..sort();
  final stops = [for (final k in keys) bySeq[k]!];
  if (stops.isNotEmpty) stops.first.departureMin ??= departureMin;
  return stops;
}

// ---------------------------------------------------------------------------
// Route revisions: a route is one or two linked journeys (outbound / return).
// ---------------------------------------------------------------------------

/// One direction of a route being edited (the outbound journey, or the return journey of a round trip).
/// [startMin] is the departure clock time at the starting point and [durationMin] the minutes until the
/// destination arrival; each intermediate stop has its own arrival offset and dwell (see stop_schedule.dart).
class JourneyDraft {
  JourneyDraft({
    this.sourceId,
    this.destId,
    List<RouteStop>? stops,
    Set<int>? days,
    this.departureDayOffset = 0,
    this.reverseGenerated = false,
    this.startMin,
    this.durationMin,
  })  : stops = stops ??
            [
              RouteStop(name: '', isBoarding: true),
              RouteStop(name: '', isDropping: true),
            ],
        days = days ?? {1, 2, 3, 4, 5, 6, 7};

  String? sourceId;
  String? destId;
  List<RouteStop> stops;
  Set<int> days;

  /// 0 = the return runs the same day as the outbound, 1 = next day, ...
  int departureDayOffset;
  bool reverseGenerated;

  /// Departure clock time at the starting point (minutes since midnight).
  int? startMin;

  /// Minutes from the departure to the destination arrival.
  int? durationMin;

  int? get departureMin => startMin;

  List<String> validate() => validateJourney(this);
}

String _hhmmss(int minutes) =>
    '${(minutes ~/ 60 % 24).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}:00';

/// Payload of one journey for save_route_revision. Drafts may be incomplete, so a stop without a
/// location is left out (the server needs a location for every stored stop). Stored offsets are the
/// calculated schedule: arrival, and departure = arrival + dwell. The origin is at offset 0 and the
/// destination arrives at the journey duration.
Map<String, dynamic> journeyToPayload(JourneyDraft j) {
  final dur = j.durationMin;
  final last = j.stops.length - 1;
  int? arrival(int i) => i == 0 ? 0 : (i == last ? dur : j.stops[i].arrivalOffset);
  int? departure(int i) {
    if (i == 0) return 0;
    if (i == last) return dur;
    final a = j.stops[i].arrivalOffset;
    return a == null ? null : a + j.stops[i].dwellMin;
  }

  return {
    'source_city_id': j.sourceId,
    'destination_city_id': j.destId,
    'departure_time': j.startMin == null ? null : _hhmmss(j.startMin!),
    'duration_min': dur,
    'operating_days': (j.days.toList()..sort()),
    'departure_day_offset': j.departureDayOffset,
    'reverse_generated': j.reverseGenerated,
    'stops': [
      for (var i = 0; i < j.stops.length; i++)
        if (j.stops[i].cityId != null)
          {
            'city_id': j.stops[i].cityId,
            'is_boarding': j.stops[i].isBoarding,
            'is_dropping': j.stops[i].isDropping,
            'arrival_offset_min': arrival(i),
            'departure_offset_min': departure(i),
            'address': j.stops[i].address,
          },
    ],
  };
}

/// Rebuilds a journey from a `route_revision_journeys` row that embeds `route_revision_stops`
/// (each with `location: {name}`). Stored offsets become arrival offsets and dwell times. A journey
/// with no departure time yet (a freshly generated reverse route) keeps its stops as automatic
/// estimates, to be placed once the user sets the departure and arrival times.
JourneyDraft journeyFromRevision(Map<String, dynamic> row) {
  final depText = row['departure_time'] as String?;
  int? startMin;
  if (depText != null) {
    final parts = depText.split(':');
    startMin = int.parse(parts[0]) * 60 + int.parse(parts[1]);
  }
  final raw = List<Map<String, dynamic>>.from((row['route_revision_stops'] as List?) ?? const [])
    ..sort((a, b) => (a['sequence_no'] as int).compareTo(b['sequence_no'] as int));

  final stops = [
    for (final s in raw)
      RouteStop(
        name: ((s['location'] as Map?)?['name'] as String?) ?? '',
        cityId: s['city_id'] as String?,
        isBoarding: s['is_boarding'] == true,
        isDropping: s['is_dropping'] == true,
        address: s['address'] as String?,
        arrivalOffset: (s['arrival_offset_min'] as num?)?.toInt(),
        dwellMin: _dwellOf(s),
        manualTime: startMin != null,
      ),
  ];
  final sourceId = row['source_city_id'] as String?;
  final destId = row['destination_city_id'] as String?;
  // A draft may have been saved before every stop had a location: pad the two ends.
  if (stops.isEmpty || stops.first.cityId != sourceId) {
    stops.insert(0, RouteStop(name: '', isBoarding: true, cityId: sourceId));
  }
  if (stops.length < 2 || stops.last.cityId != destId) {
    stops.add(RouteStop(name: '', isDropping: true, cityId: destId));
  }

  return JourneyDraft(
    sourceId: sourceId,
    destId: destId,
    stops: stops,
    days: {for (final d in (row['operating_days'] as List? ?? const [1, 2, 3, 4, 5, 6, 7])) (d as num).toInt()},
    departureDayOffset: (row['departure_day_offset'] as num?)?.toInt() ?? 0,
    reverseGenerated: row['reverse_generated'] == true,
    startMin: startMin,
    durationMin: (row['est_duration_min'] as num?)?.toInt(),
  );
}

int _dwellOf(Map<String, dynamic> stop) {
  final a = (stop['arrival_offset_min'] as num?)?.toInt();
  final d = (stop['departure_offset_min'] as num?)?.toInt();
  if (a == null || d == null || d < a) return 5;
  return d - a;
}

/// Names of the stops follow the location master list (stop names are always the location name).
void syncStopNames(List<RouteStop> stops, List<Map<String, dynamic>> locations) {
  for (final s in stops) {
    if (s.cityId == null) continue;
    final match = locations.where((l) => l['id'] == s.cityId);
    if (match.isNotEmpty) s.name = match.first['name'] as String? ?? s.name;
  }
}

/// Mirrors generate_reverse_route in SQL, for previews: stops reversed, pickup / drop swapped, stop
/// times kept. The outbound clock times are NOT copied: the return has its own departure and arrival
/// (left unset), and its stops are automatic estimates until the operator adjusts them.
JourneyDraft reverseJourney(JourneyDraft outbound) {
  final n = outbound.stops.length;
  final dur = outbound.durationMin;
  final stops = <RouteStop>[];
  for (var i = n - 1; i >= 0; i--) {
    final s = outbound.stops[i];
    final a = s.arrivalOffset;
    stops.add(RouteStop(
      name: s.name,
      cityId: s.cityId,
      address: s.address,
      isBoarding: s.isDropping,
      isDropping: s.isBoarding,
      dwellMin: s.dwellMin,
      arrivalOffset: (dur == null || a == null || i == 0 || i == n - 1) ? null : dur - (a + s.dwellMin),
      manualTime: false,
    ));
  }
  return JourneyDraft(
    sourceId: outbound.destId,
    destId: outbound.sourceId,
    stops: stops,
    days: {...outbound.days},
    reverseGenerated: true,
    durationMin: dur,
  );
}
