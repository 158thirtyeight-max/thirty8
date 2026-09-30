/// Pure model for a bus's route (Stage D): ordered stops with clock times.
/// Clock times are what the operator thinks in; the database stores minute
/// offsets from the origin departure, unwrapped across midnight so overnight
/// journeys stay monotonic. `validateRoute` mirrors `validate_bus_route` in SQL.
library;

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
