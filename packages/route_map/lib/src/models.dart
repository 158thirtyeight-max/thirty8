import 'geo.dart';

enum RouteDirection { outbound, returning }

class RouteStop {
  const RouteStop({required this.locationId, required this.name, required this.order, required this.isPickup, required this.isDrop, this.point});

  final String locationId;
  final String name;
  final int order;
  final bool isPickup;
  final bool isDrop;

  /// Null when the stop has no coordinates; such a stop is listed but never drawn.
  final GeoPoint? point;

  factory RouteStop.fromJson(Map<String, dynamic> j) {
    final lat = (j['latitude'] as num?)?.toDouble(), lng = (j['longitude'] as num?)?.toDouble();
    return RouteStop(
      locationId: j['location_id'] as String,
      name: (j['name'] as String?) ?? '',
      order: (j['order'] as num).toInt(),
      isPickup: j['is_pickup'] == true,
      isDrop: j['is_drop'] == true,
      point: lat == null || lng == null ? null : GeoPoint(lat, lng),
    );
  }
}

/// The stored road geometry of a route. [isCurrent] is false when the stops changed after it was
/// built; such a geometry is never drawn as the route.
class RoadGeometry {
  const RoadGeometry({required this.points, required this.isCurrent, this.distanceM});

  final List<GeoPoint> points;
  final bool isCurrent;
  final double? distanceM;
}

class RouteMapData {
  const RouteMapData({
    required this.tripId,
    required this.routeId,
    required this.direction,
    required this.tripStatus,
    required this.stops,
    this.geometry,
    this.myPickupLocationId,
    this.myDropLocationId,
  });

  final String tripId;
  final String routeId;
  final RouteDirection direction;
  final String tripStatus;
  final List<RouteStop> stops;
  final RoadGeometry? geometry;
  final String? myPickupLocationId;
  final String? myDropLocationId;

  List<RouteStop> get drawableStops => [for (final s in stops) if (s.point != null) s];

  /// The road line to draw: only a current geometry, never a straight line between stops.
  List<GeoPoint>? get roadLine => geometry != null && geometry!.isCurrent && geometry!.points.length >= 2 ? geometry!.points : null;

  /// True when a road route should exist but is missing or out of date (operators can rebuild it).
  bool get needsGeometry => drawableStops.length >= 2 && roadLine == null;

  String get title => stops.length < 2 ? '' : '${stops.first.name} → ${stops.last.name}';

  factory RouteMapData.fromJson(Map<String, dynamic> j) {
    final g = j['geometry'] as Map?;
    RoadGeometry? geometry;
    if (g != null) {
      List<GeoPoint> pts;
      try {
        pts = decodePolyline(g['polyline6'] as String);
      } on FormatException {
        pts = const [];
      }
      geometry = RoadGeometry(points: pts, isCurrent: g['is_current'] == true, distanceM: (g['distance_m'] as num?)?.toDouble());
    }
    final stops = [for (final s in (j['stops'] as List? ?? const [])) RouteStop.fromJson(Map<String, dynamic>.from(s as Map))]
      ..sort((a, b) => a.order.compareTo(b.order));
    return RouteMapData(
      tripId: j['trip_id'] as String,
      routeId: j['route_id'] as String,
      direction: j['direction'] == 'return' ? RouteDirection.returning : RouteDirection.outbound,
      tripStatus: (j['trip_status'] as String?) ?? '',
      stops: stops,
      geometry: geometry,
      myPickupLocationId: j['my_pickup_location_id'] as String?,
      myDropLocationId: j['my_drop_location_id'] as String?,
    );
  }
}
