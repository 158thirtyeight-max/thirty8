import 'dart:async';

import 'package:design_system/design_system.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'bus_marker.dart';
import 'geo.dart';
import 'live_fix.dart';
import 'models.dart';
import 'tracking_view.dart';
import 'trip_map_feed.dart';

/// Map style. OpenFreeMap needs no API key; override with `--dart-define=MAP_STYLE_URL=...` to use a
/// self-hosted style. Attribution (OpenFreeMap, OpenMapTiles, OpenStreetMap contributors) is shown on the map.
const mapStyleUrl = String.fromEnvironment('MAP_STYLE_URL', defaultValue: 'https://tiles.openfreemap.org/styles/liberty');

const _routeColor = '#6D28D9';
const _fontNames = ['Noto Sans Regular'];

LatLng _ll(GeoPoint p) => LatLng(p.lat, p.lng);

/// The trip map: stored road-following route, ordered stops (the customer's own pickup and drop
/// highlighted) and the live bus position, with an honest status line.
///
/// Place it inside an existing screen; it is a card, not a screen. If the map cannot load it shows a
/// fallback and the rest of the screen keeps working.
class TripMapCard extends StatefulWidget {
  const TripMapCard({
    super.key,
    required this.client,
    required this.tripId,
    this.height = 300,
    this.showTripStatus = false,
    this.buildGeometry,
  });

  final SupabaseClient client;
  final String tripId;
  final double height;

  /// Operator view: also show the trip status.
  final bool showTripStatus;

  /// Operator view: asked once when the trip's route has no current road geometry. Should call the
  /// `route-geometry` Edge Function; the card reloads the route afterwards.
  final Future<void> Function(String routeId)? buildGeometry;

  @override
  State<TripMapCard> createState() => _TripMapCardState();
}

class _TripMapCardState extends State<TripMapCard> with SingleTickerProviderStateMixin {
  late TripMapFeed _feed;
  MapLibreMapController? _map;
  bool _styleLoaded = false;
  bool _mapFailed = false;
  int _mapKey = 0;
  Timer? _loadTimeout;
  Timer? _clock;
  bool _geometryRequested = false;

  String? _drawnRouteKey;
  bool _fitted = false;
  Symbol? _busSymbol;
  Fill? _accuracyFill;
  String? _busImage;
  String? _lastFixKey;
  GeoPoint? _shown;
  late final AnimationController _anim;
  final _images = <String>{};

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));
    _startFeed();
    // Ages and the live -> last-updated transition depend on the clock, not only on new data.
    _clock = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!mounted) return;
      setState(() {});
      _syncBus();
    });
    _armLoadTimeout();
  }

  void _startFeed() {
    _feed = TripMapFeed(client: widget.client, tripId: widget.tripId)..addListener(_onFeed);
    _feed.start();
  }

  void _armLoadTimeout() {
    _loadTimeout?.cancel();
    _loadTimeout = Timer(const Duration(seconds: 15), () {
      if (mounted && !_styleLoaded) setState(() => _mapFailed = true);
    });
  }

  @override
  void didUpdateWidget(TripMapCard old) {
    super.didUpdateWidget(old);
    if (old.tripId != widget.tripId || old.client != widget.client) {
      _feed.removeListener(_onFeed);
      _feed.dispose();
      _resetMap();
      _startFeed();
    }
  }

  void _resetMap() {
    _map = null;
    _styleLoaded = false;
    _drawnRouteKey = null;
    _fitted = false;
    _busSymbol = null;
    _accuracyFill = null;
    _busImage = null;
    _lastFixKey = null;
    _shown = null;
    _images.clear();
    _geometryRequested = false;
    _mapKey++;
  }

  @override
  void dispose() {
    _clock?.cancel();
    _loadTimeout?.cancel();
    _anim.dispose();
    _feed.removeListener(_onFeed);
    _feed.dispose();
    super.dispose();
  }

  void _onFeed() {
    if (!mounted) return;
    setState(() {});
    _maybeBuildGeometry();
    if (_styleLoaded) {
      _syncRoute();
      _syncBus();
    }
  }

  Future<void> _maybeBuildGeometry() async {
    final r = _feed.route;
    final build = widget.buildGeometry;
    if (r == null || build == null || _geometryRequested || !r.needsGeometry) return;
    _geometryRequested = true;
    try {
      await build(r.routeId);
      if (mounted) await _feed.loadRoute();
    } catch (_) {
      // Stays on "road route not available yet"; the rest of the map keeps working.
    }
  }

  // ---------------------------------------------------------------- map lifecycle

  Future<void> _onStyleLoaded() async {
    final c = _map;
    if (c == null) return;
    _loadTimeout?.cancel();
    try {
      await c.setSymbolIconAllowOverlap(true);
      await c.setSymbolTextAllowOverlap(false);
      _styleLoaded = true;
      if (mounted && _mapFailed) setState(() => _mapFailed = false);
      await _syncRoute();
      await _syncBus();
    } catch (_) {
      if (mounted) setState(() => _mapFailed = true);
    }
  }

  String _routeKey(RouteMapData r) => '${r.routeId}|${r.roadLine?.length}|${r.drawableStops.length}|${r.myPickupLocationId}|${r.myDropLocationId}';

  Future<void> _syncRoute() async {
    final c = _map, r = _feed.route;
    if (c == null || r == null || !_styleLoaded) return;
    final key = _routeKey(r);
    if (key == _drawnRouteKey) return;
    _drawnRouteKey = key;
    try {
      await c.clearLines();
      await c.clearCircles();
      await c.clearSymbols();
      await c.clearFills();
      _busSymbol = null;
      _accuracyFill = null;
      _lastFixKey = null;

      final road = r.roadLine;
      if (road != null) {
        await c.addLine(LineOptions(geometry: [for (final p in road) _ll(p)], lineColor: '#FFFFFF', lineWidth: 8, lineOpacity: 0.9, lineJoin: 'round'));
        await c.addLine(LineOptions(geometry: [for (final p in road) _ll(p)], lineColor: _routeColor, lineWidth: 5, lineJoin: 'round'));
      }

      final stops = r.drawableStops;
      for (var i = 0; i < stops.length; i++) {
        final s = stops[i];
        final first = i == 0, last = i == stops.length - 1;
        final mine = s.locationId == r.myPickupLocationId ? 'pickup' : (s.locationId == r.myDropLocationId ? 'drop' : null);
        final color = mine == 'pickup' ? '#10B981' : (mine == 'drop' ? '#EF4444' : (first ? '#1E1B2E' : (last ? '#1E1B2E' : '#FFFFFF')));
        final stroke = (mine != null || first || last) ? '#FFFFFF' : _routeColor;
        await c.addCircle(CircleOptions(
          geometry: _ll(s.point!),
          circleRadius: mine != null ? 9 : (first || last ? 8 : 5.5),
          circleColor: color,
          circleStrokeColor: stroke,
          circleStrokeWidth: 3,
        ));
        final tag = mine == 'pickup' ? 'Your pickup · ' : (mine == 'drop' ? 'Your drop · ' : '');
        await c.addSymbol(SymbolOptions(
          geometry: _ll(s.point!),
          textField: '$tag${s.order}. ${s.name}',
          textSize: mine != null ? 12.5 : 11,
          textOffset: const Offset(0, 1.1),
          textAnchor: 'top',
          textColor: '#1E1B2E',
          textHaloColor: '#FFFFFF',
          textHaloWidth: 1.6,
          fontNames: _fontNames,
        ));
      }
      if (!_fitted) await _fitAll();
    } catch (_) {
      _drawnRouteKey = null; // retry on the next change
    }
  }

  Future<void> _fitAll() async {
    final c = _map, r = _feed.route;
    if (c == null || r == null) return;
    final pts = <GeoPoint>[
      ...?r.roadLine,
      for (final s in r.drawableStops) s.point!,
      if (_shownFix?.point != null) _shownFix!.point!,
    ];
    if (pts.isEmpty) return;
    _fitted = true;
    var minLat = pts.first.lat, maxLat = pts.first.lat, minLng = pts.first.lng, maxLng = pts.first.lng;
    for (final p in pts) {
      if (p.lat < minLat) minLat = p.lat;
      if (p.lat > maxLat) maxLat = p.lat;
      if (p.lng < minLng) minLng = p.lng;
      if (p.lng > maxLng) maxLng = p.lng;
    }
    try {
      if (maxLat - minLat < 0.0005 && maxLng - minLng < 0.0005) {
        await c.animateCamera(CameraUpdate.newLatLngZoom(LatLng(minLat, minLng), 14));
      } else {
        await c.animateCamera(CameraUpdate.newLatLngBounds(
          LatLngBounds(southwest: LatLng(minLat, minLng), northeast: LatLng(maxLat, maxLng)),
          left: 36,
          right: 36,
          top: 36,
          bottom: 48,
        ));
      }
    } catch (_) {}
  }

  LiveFix? get _shownFix {
    final v = describeTracking(_feed.fix, DateTime.now());
    return v.showBus ? _feed.fix : null;
  }

  // ---------------------------------------------------------------- bus marker

  Color _colorFor(TrackingKind k) => switch (k) {
        TrackingKind.live => AppColors.success,
        TrackingKind.estimated => AppColors.info,
        TrackingKind.lastKnown => AppColors.warning,
        _ => AppColors.textTertiary,
      };

  String _imageName(TrackingKind k, bool arrow) => 'bus-${k.name}-${arrow ? 'dir' : 'plain'}';

  Future<void> _ensureImage(MapLibreMapController c, TrackingKind k, bool arrow) async {
    final name = _imageName(k, arrow);
    if (_images.contains(name)) return;
    await c.addImage(name, await renderBusMarker(color: _colorFor(k), withArrow: arrow, hollow: k == TrackingKind.estimated));
    _images.add(name);
  }

  Future<void> _syncBus() async {
    final c = _map;
    if (c == null || !_styleLoaded || _drawnRouteKey == null) return;
    final fix = _feed.fix;
    final view = describeTracking(fix, DateTime.now());
    final p = view.showBus ? fix?.point : null;
    try {
      if (p == null) {
        await _removeBus(c);
        return;
      }
      final arrow = fix!.heading != null && view.kind != TrackingKind.estimated;
      await _ensureImage(c, view.kind, arrow);
      final image = _imageName(view.kind, arrow);
      final rotate = arrow ? fix.heading! : 0.0;

      if (_busSymbol == null) {
        _shown = p;
        _busImage = image;
        _busSymbol = await c.addSymbol(SymbolOptions(geometry: _ll(p), iconImage: image, iconSize: 0.62, iconRotate: rotate, iconAnchor: 'center', zIndex: 10));
        _lastFixKey = fix.fixKey;
        await _syncAccuracy(c, fix, view);
        if (!_fitted) await _fitAll();
        return;
      }
      if (fix.fixKey == _lastFixKey && image == _busImage) return;
      _lastFixKey = fix.fixKey;
      final from = _shown ?? p;
      final jump = distanceM(from, p);
      final symbol = _busSymbol!;
      if (image != _busImage) {
        _busImage = image;
        await c.updateSymbol(symbol, SymbolOptions(iconImage: image, iconRotate: rotate));
      }
      await _syncAccuracy(c, fix, view);
      // Glide between two real GPS readings; a big jump (or no movement) is shown as it is.
      if (jump < 2 || jump > 1500) {
        _shown = p;
        await c.updateSymbol(symbol, SymbolOptions(geometry: _ll(p), iconRotate: rotate));
        return;
      }
      _glide(c, symbol, from, p, rotate);
    } catch (_) {
      // A failed marker update must never break the screen; the next fix redraws it.
    }
  }

  void _glide(MapLibreMapController c, Symbol symbol, GeoPoint from, GeoPoint to, double rotate) {
    _anim
      ..stop()
      ..reset();
    var busy = false;
    void tick() async {
      if (busy || !mounted) return;
      busy = true;
      final t = Curves.easeInOut.transform(_anim.value);
      final p = GeoPoint(from.lat + (to.lat - from.lat) * t, from.lng + (to.lng - from.lng) * t);
      _shown = p;
      try {
        await c.updateSymbol(symbol, SymbolOptions(geometry: _ll(p), iconRotate: rotate));
      } catch (_) {}
      busy = false;
    }

    _anim
      ..removeListener(tick)
      ..addListener(tick)
      ..forward().whenComplete(() => _anim.removeListener(tick));
  }

  Future<void> _removeBus(MapLibreMapController c) async {
    final s = _busSymbol;
    _busSymbol = null;
    _lastFixKey = null;
    _shown = null;
    if (s != null) await c.removeSymbol(s);
    final f = _accuracyFill;
    _accuracyFill = null;
    if (f != null) await c.removeFill(f);
  }

  Future<void> _syncAccuracy(MapLibreMapController c, LiveFix fix, TrackingView view) async {
    final old = _accuracyFill;
    _accuracyFill = null;
    if (old != null) await c.removeFill(old);
    final acc = fix.accuracyM;
    // Poor GPS is drawn as an uncertainty area instead of pretending to be a precise point.
    if (fix.point == null || acc == null || acc < 30) return;
    final color = view.kind == TrackingKind.live ? '#10B981' : '#9B96AC';
    _accuracyFill = await c.addFill(FillOptions(
      geometry: [[for (final p in circleRing(fix.point!, acc)) _ll(p)]],
      fillColor: color,
      fillOpacity: 0.15,
      fillOutlineColor: color,
    ));
  }

  Future<void> _centerOnBus() async {
    final c = _map, p = _shownFix?.point;
    if (c == null || p == null) return;
    final zoom = c.cameraPosition?.zoom ?? 0;
    try {
      await c.animateCamera(CameraUpdate.newLatLngZoom(_ll(_shown ?? p), zoom < 13 ? 14 : zoom));
    } catch (_) {}
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final route = _feed.route;
    final now = DateTime.now();
    final view = describeTracking(_feed.trackingFailed && _feed.fix == null ? null : _feed.fix, now);

    if (_feed.routeLoading && route == null) {
      return AppCard(child: SizedBox(height: widget.height, child: const AppLoadingState()));
    }
    if (route == null) {
      return AppCard(
        child: _Fallback(
          height: widget.height,
          title: 'Map unavailable',
          message: 'Your trip details are still available.\nPlease check your internet connection.',
          onRetry: () {
            _feed.loadRoute();
            _feed.loadTracking();
          },
        ),
      );
    }

    final road = route.roadLine;
    final fix = _shownFix;
    final progress = (road != null && fix?.point != null) ? routeProgress(road, fix!.point!) : null;
    final offRoute = progress != null && progress.offRouteM > 500;
    final canShowMap = route.drawableStops.isNotEmpty && !_mapFailed;

    return AppCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
            child: SizedBox(
              height: widget.height,
              child: !canShowMap
                  ? _Fallback(
                      height: widget.height,
                      title: route.drawableStops.isEmpty ? 'Route map not available' : 'Map unavailable',
                      message: route.drawableStops.isEmpty
                          ? 'This trip has no map coordinates yet. Your trip details are still available.'
                          : 'Your trip details are still available.\nPlease check your internet connection.',
                      onRetry: route.drawableStops.isEmpty
                          ? null
                          : () => setState(() {
                                _resetMap();
                                _mapFailed = false;
                                _armLoadTimeout();
                              }),
                    )
                  : Stack(children: [
                      MapLibreMap(
                        key: ValueKey(_mapKey),
                        styleString: mapStyleUrl,
                        initialCameraPosition: CameraPosition(target: _ll(route.drawableStops.first.point!), zoom: 9),
                        onMapCreated: (c) => _map = c,
                        onStyleLoadedCallback: _onStyleLoaded,
                        compassEnabled: false,
                        rotateGesturesEnabled: false,
                        tiltGesturesEnabled: false,
                        attributionButtonPosition: AttributionButtonPosition.bottomLeft,
                        gestureRecognizers: {Factory<OneSequenceGestureRecognizer>(() => EagerGestureRecognizer())},
                      ),
                      Positioned(
                        right: 8,
                        top: 8,
                        child: Column(children: [
                          _MapButton(icon: Icons.fit_screen_outlined, tooltip: 'Show whole route', onTap: () {
                            _fitted = false;
                            _fitAll();
                          }),
                          if (fix?.point != null) ...[
                            const SizedBox(height: 8),
                            _MapButton(icon: Icons.directions_bus, tooltip: 'Centre on bus', onTap: _centerOnBus),
                          ],
                        ]),
                      ),
                    ]),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Container(width: 10, height: 10, decoration: BoxDecoration(color: _colorFor(view.kind), shape: BoxShape.circle)),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(child: Text(view.headline, style: theme.textTheme.titleSmall)),
                  _Chip(route.direction == RouteDirection.returning ? 'Return' : 'Outbound'),
                ]),
                if (view.detail != null) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text(view.detail!, style: theme.textTheme.bodySmall),
                ],
                if (_feed.trackingFailed && _feed.fix != null) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text('Could not refresh. Showing the last data received.', style: theme.textTheme.bodySmall?.copyWith(color: AppColors.warning)),
                ],
                if (route.title.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Text(route.title, style: theme.textTheme.bodyMedium),
                ],
                if (widget.showTripStatus) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text('Trip status: ${_feed.fix?.tripStatus ?? route.tripStatus}', style: theme.textTheme.bodySmall),
                ],
                if (progress != null && !offRoute) ...[
                  const SizedBox(height: AppSpacing.sm),
                  ClipRRect(
                    borderRadius: AppRadius.pillRadius,
                    child: LinearProgressIndicator(value: progress.fraction, minHeight: 6, backgroundColor: AppColors.divider),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    'Route progress ${(progress.fraction * 100).round()}% · ${(progress.alongM / 1000).toStringAsFixed(0)} of ${(progress.totalM / 1000).toStringAsFixed(0)} km',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
                if (offRoute) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text('The bus appears to be away from the planned route.', style: theme.textTheme.bodySmall?.copyWith(color: AppColors.warning)),
                ],
                if (route.needsGeometry) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    widget.buildGeometry != null && !_geometryRequested ? 'Preparing the road route…' : 'Road route not available yet. Stops are shown on the map.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
                const SizedBox(height: AppSpacing.sm),
                Wrap(spacing: 14, runSpacing: 4, children: [
                  if (route.myPickupLocationId != null) const _LegendDot(color: AppColors.success, label: 'Your pickup'),
                  if (route.myDropLocationId != null) const _LegendDot(color: AppColors.error, label: 'Your drop'),
                  const _LegendDot(color: AppColors.primary, label: 'Stop'),
                ]),
                const SizedBox(height: AppSpacing.xs),
                Text('© OpenStreetMap contributors · OpenFreeMap', style: theme.textTheme.labelSmall?.copyWith(color: AppColors.textTertiary)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Fallback extends StatelessWidget {
  const _Fallback({required this.height, required this.title, required this.message, this.onRetry});

  final double height;
  final String title;
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: height,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.map_outlined, size: 40, color: AppColors.textTertiary),
          const SizedBox(height: AppSpacing.sm),
          Text(title, style: theme.textTheme.titleMedium),
          const SizedBox(height: AppSpacing.xs),
          Text(message, textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
          if (onRetry != null) ...[
            const SizedBox(height: AppSpacing.sm),
            TextButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ]),
      ),
    );
  }
}

class _MapButton extends StatelessWidget {
  const _MapButton({required this.icon, required this.tooltip, required this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.white,
        elevation: 2,
        shape: const CircleBorder(),
        child: IconButton(icon: Icon(icon, size: 20, color: AppColors.textPrimary), tooltip: tooltip, onPressed: onTap, visualDensity: VisualDensity.compact),
      );
}

class _Chip extends StatelessWidget {
  const _Chip(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(color: AppColors.primaryLight.withValues(alpha: 0.35), borderRadius: AppRadius.pillRadius),
        child: Text(label, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: AppColors.primaryDark)),
      );
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 4),
        Text(label, style: Theme.of(context).textTheme.labelSmall),
      ]);
}
