import 'dart:math' as math;

/// A plain coordinate, independent of the map plugin so the maths can be tested without it.
class GeoPoint {
  const GeoPoint(this.lat, this.lng);

  final double lat;
  final double lng;

  @override
  bool operator ==(Object other) => other is GeoPoint && other.lat == lat && other.lng == lng;

  @override
  int get hashCode => Object.hash(lat, lng);

  @override
  String toString() => 'GeoPoint($lat, $lng)';
}

/// Decodes an encoded polyline. OSRM `geometries=polyline6` uses [precision] 6.
List<GeoPoint> decodePolyline(String encoded, {int precision = 6}) {
  final factor = math.pow(10, precision).toDouble();
  final out = <GeoPoint>[];
  var index = 0, lat = 0, lng = 0;
  int next() {
    var result = 0, shift = 0;
    int b;
    do {
      if (index >= encoded.length) throw const FormatException('Truncated polyline');
      b = encoded.codeUnitAt(index++) - 63;
      result |= (b & 0x1f) << shift;
      shift += 5;
    } while (b >= 0x20);
    return (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
  }

  while (index < encoded.length) {
    lat += next();
    lng += next();
    out.add(GeoPoint(lat / factor, lng / factor));
  }
  return out;
}

const _earthRadiusM = 6371008.8;

double _rad(double d) => d * math.pi / 180;

double distanceM(GeoPoint a, GeoPoint b) {
  final dLat = _rad(b.lat - a.lat), dLng = _rad(b.lng - a.lng);
  final h = math.pow(math.sin(dLat / 2), 2) + math.cos(_rad(a.lat)) * math.cos(_rad(b.lat)) * math.pow(math.sin(dLng / 2), 2);
  return 2 * _earthRadiusM * math.asin(math.min(1, math.sqrt(h)));
}

/// How far along the road route the bus is, and how far from the road line it sits.
class RouteProgress {
  const RouteProgress({required this.fraction, required this.alongM, required this.totalM, required this.offRouteM});

  /// 0..1 of the way from the first to the last point of the line.
  final double fraction;
  final double alongM;
  final double totalM;

  /// Distance from the nearest point of the line. Large values mean the bus is not on this route.
  final double offRouteM;
}

/// Projects [p] onto [line] (local flat approximation, fine at route scale). Null for lines < 2 points.
RouteProgress? routeProgress(List<GeoPoint> line, GeoPoint p) {
  if (line.length < 2) return null;
  final cosLat = math.cos(_rad(p.lat));
  (double, double) xy(GeoPoint g) => (_rad(g.lng - p.lng) * cosLat * _earthRadiusM, _rad(g.lat - p.lat) * _earthRadiusM);

  var bestAlong = 0.0, bestDist = double.infinity, walked = 0.0;
  for (var i = 0; i < line.length - 1; i++) {
    final segLen = distanceM(line[i], line[i + 1]);
    final (ax, ay) = xy(line[i]);
    final (bx, by) = xy(line[i + 1]);
    final dx = bx - ax, dy = by - ay;
    final len2 = dx * dx + dy * dy;
    final t = len2 == 0 ? 0.0 : ((-ax * dx - ay * dy) / len2).clamp(0.0, 1.0);
    final px = ax + t * dx, py = ay + t * dy;
    final d = math.sqrt(px * px + py * py);
    if (d < bestDist) {
      bestDist = d;
      bestAlong = walked + t * segLen;
    }
    walked += segLen;
  }
  return RouteProgress(fraction: walked == 0 ? 0 : (bestAlong / walked).clamp(0.0, 1.0), alongM: bestAlong, totalM: walked, offRouteM: bestDist);
}

/// A closed ring approximating a circle of [radiusM] metres, for drawing GPS accuracy.
List<GeoPoint> circleRing(GeoPoint c, double radiusM, {int steps = 36}) {
  final dLat = radiusM / _earthRadiusM * 180 / math.pi;
  final dLng = dLat / math.max(0.01, math.cos(_rad(c.lat)));
  return [
    for (var i = 0; i <= steps; i++) GeoPoint(c.lat + dLat * math.sin(2 * math.pi * i / steps), c.lng + dLng * math.cos(2 * math.pi * i / steps)),
  ];
}
