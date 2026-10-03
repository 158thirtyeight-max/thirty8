/// Pure scheduling math for intermediate stops. No Flutter or Supabase here so
/// it stays unit-testable.
///
/// Everything is a minute offset from the service's departure (0 = origin
/// departure). Stop purposes and facilities never feed into these calculations:
///
///   departure = arrival + duration
library;

class StopDraft {
  StopDraft({
    required this.locationCityId,
    required this.locationName,
    required this.arrivalOffset,
    this.durationMinutes = 2,
    this.allowsPickup = true,
    this.allowsDrop = true,
    List<String>? purposes,
    List<String>? mealTypes,
    List<String>? refreshmentTypes,
    List<String>? facilities,
  })  : purposes = {...?purposes},
        mealTypes = {...?mealTypes},
        refreshmentTypes = {...?refreshmentTypes},
        facilities = {...?facilities};

  String locationCityId;
  String locationName;
  int arrivalOffset;
  int durationMinutes;
  bool allowsPickup;
  bool allowsDrop;
  final Set<String> purposes;
  final Set<String> mealTypes;
  final Set<String> refreshmentTypes;
  final Set<String> facilities;

  int get departureOffset => arrivalOffset + durationMinutes;

  StopDraft copy() => StopDraft(
        locationCityId: locationCityId,
        locationName: locationName,
        arrivalOffset: arrivalOffset,
        durationMinutes: durationMinutes,
        allowsPickup: allowsPickup,
        allowsDrop: allowsDrop,
        purposes: purposes.toList(),
        mealTypes: mealTypes.toList(),
        refreshmentTypes: refreshmentTypes.toList(),
        facilities: facilities.toList(),
      );

  /// Drops sub-options whose parent purpose is no longer selected, so removing
  /// "Meal Break" can never leave a stale "Lunch" behind.
  void pruneSubOptions() {
    if (!purposes.contains('meal_break')) mealTypes.clear();
    if (!purposes.contains('tea_refreshment')) refreshmentTypes.clear();
  }

  /// Row for the save_service_stops RPC (arrays only; the DB generates departure).
  Map<String, dynamic> toRpc() => {
        'location_city_id': locationCityId,
        'allows_pickup': allowsPickup,
        'allows_drop': allowsDrop,
        'arrival_offset_minutes': arrivalOffset,
        'stop_duration_minutes': durationMinutes,
        'stop_purposes': purposes.toList()..sort(),
        'meal_types': mealTypes.toList()..sort(),
        'refreshment_types': refreshmentTypes.toList()..sort(),
        'facilities': facilities.toList()..sort(),
      };

  /// Reads a bus_service_stops row (joined with `cities(name)`). Missing array
  /// columns (stops saved before purposes existed) read as empty.
  factory StopDraft.fromRow(Map<String, dynamic> row) {
    List<String> list(String key) => ((row[key] as List<dynamic>?) ?? const []).map((e) => e as String).toList();
    return StopDraft(
      locationCityId: row['location_city_id'] as String,
      locationName: (row['cities'] as Map?)?['name'] as String? ?? '',
      arrivalOffset: (row['arrival_offset_minutes'] as num).toInt(),
      durationMinutes: (row['stop_duration_minutes'] as num?)?.toInt() ?? 2,
      allowsPickup: row['allows_pickup'] as bool? ?? true,
      allowsDrop: row['allows_drop'] as bool? ?? true,
      purposes: list('stop_purposes'),
      mealTypes: list('meal_types'),
      refreshmentTypes: list('refreshment_types'),
      facilities: list('facilities'),
    );
  }
}

/// Inclusive range of minute offsets a stop can arrive at, given its
/// neighbours. [min] > [max] means there is no room for it.
class ArrivalWindow {
  const ArrivalWindow(this.min, this.max);

  final int min;
  final int max;

  bool get isEmpty => min > max;
  bool contains(int v) => v >= min && v <= max;
  int clamp(int v) => v < min ? min : (v > max ? max : v);
}

/// The window for a stop with [durationMinutes]: it must arrive after the
/// previous stop departs ([prevDeparture], 0 for the first stop) and depart
/// before the next stop arrives ([nextArrival]) or the bus reaches the
/// destination ([totalMinutes]).
ArrivalWindow arrivalWindow({
  required int prevDeparture,
  required int? nextArrival,
  required int totalMinutes,
  required int durationMinutes,
}) {
  final limit = nextArrival ?? totalMinutes;
  return ArrivalWindow(prevDeparture + 1, limit - durationMinutes - 1);
}

/// Longest duration the stop can have at [arrivalOffset] without running into
/// the next stop / destination.
int maxDuration({required int arrivalOffset, required int? nextArrival, required int totalMinutes}) =>
    (nextArrival ?? totalMinutes) - arrivalOffset - 1;

/// Validates an ordered stop list against a journey of [totalMinutes].
/// Returns null when valid, otherwise a message for the operator.
String? validateStops(List<StopDraft> stops, int totalMinutes) {
  var prevDeparture = 0;
  for (var i = 0; i < stops.length; i++) {
    final s = stops[i];
    final n = i + 1;
    if (!s.allowsPickup && !s.allowsDrop) return 'Stop $n must allow pickup, drop or both';
    if (s.durationMinutes < 1) return 'Stop $n needs a stop duration of at least 1 minute';
    if (s.arrivalOffset <= prevDeparture) return 'Stop $n must arrive after the previous stop has departed';
    if (s.departureOffset >= totalMinutes) return 'Stop $n must depart before the bus reaches the destination';
    prevDeparture = s.departureOffset;
  }
  return null;
}

/// Clock label for [offsetMinutes] after a [departureMinuteOfDay] (0..1439)
/// origin departure, e.g. "04:55 (+1 day)". Handles multi-day journeys.
String clockLabel(int departureMinuteOfDay, int offsetMinutes) {
  final total = departureMinuteOfDay + offsetMinutes;
  final day = total ~/ 1440;
  final m = total % 1440;
  final hh = (m ~/ 60).toString().padLeft(2, '0');
  final mm = (m % 60).toString().padLeft(2, '0');
  return day > 0 ? '$hh:$mm (+$day day${day > 1 ? 's' : ''})' : '$hh:$mm';
}

/// "30 min", "1 h", "1 h 15 min".
String durationLabel(int minutes) {
  final h = minutes ~/ 60;
  final m = minutes % 60;
  if (h == 0) return '$m min';
  return m == 0 ? '$h h' : '$h h $m min';
}
