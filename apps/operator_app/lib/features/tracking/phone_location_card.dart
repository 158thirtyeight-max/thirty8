import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../../core/supabase_providers.dart';
import 'phone_location_publisher.dart';

/// Trips whose location may be shared from the driver phone: only while the trip is actually running.
bool phoneSharingAllowed(String tripStatus) => tripStatus == 'boarding' || tripStatus == 'departed';

PhoneFix fixFromPosition(Position p) {
  final moving = p.speed > 1.0; // m/s; a standing phone reports an unreliable heading
  return PhoneFix(
    latitude: p.latitude,
    longitude: p.longitude,
    at: p.timestamp,
    accuracyM: p.accuracy >= 0 ? p.accuracy : null,
    speedKmh: p.speed >= 0 ? p.speed * 3.6 : null,
    heading: moving && p.heading >= 0 && p.heading < 360 ? p.heading : null,
  );
}

/// "Share this phone's location": an explicit, per-trip switch. Nothing is read from the GPS until the
/// operator turns it on, and it turns itself off when the trip is no longer boarding / departed.
/// The phone is a fallback source: the server only accepts it for buses where thirty8 enabled the
/// driver-phone fallback (a working GPS tracker always takes priority).
/// Limitation: it runs while the app is open on this phone (no background service).
class PhoneLocationCard extends ConsumerStatefulWidget {
  const PhoneLocationCard({super.key, required this.tripId, required this.tripStatus});

  final String tripId;
  final String tripStatus;

  @override
  ConsumerState<PhoneLocationCard> createState() => _PhoneLocationCardState();
}

class _PhoneLocationCardState extends ConsumerState<PhoneLocationCard> {
  PhoneLocationPublisher? _publisher;
  bool _on = false;
  String? _message;

  @override
  void didUpdateWidget(PhoneLocationCard old) {
    super.didUpdateWidget(old);
    if (_on && !phoneSharingAllowed(widget.tripStatus)) _turnOff('Sharing stopped because the trip is no longer running.');
  }

  @override
  void dispose() {
    _publisher?.stop();
    super.dispose();
  }

  Future<void> _turnOn() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        setState(() => _message = 'Turn on location services on this phone.');
        return;
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        setState(() => _message = 'Location permission is needed to share the bus position.');
        return;
      }
    } catch (_) {
      setState(() => _message = 'GPS is unavailable on this phone.');
      return;
    }

    final db = ref.read(supabaseProvider);
    _publisher = PhoneLocationPublisher(
      positions: () => Geolocator.getPositionStream(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 10),
      ).map(fixFromPosition),
      send: (f) async {
        try {
          final r = await db.rpc('update_bus_location', params: {
            'p_trip_id': widget.tripId,
            'p_latitude': f.latitude,
            'p_longitude': f.longitude,
            'p_accuracy_m': f.accuracyM,
            'p_speed_kmh': f.speedKmh,
            'p_heading': f.heading,
          });
          final m = Map<String, dynamic>.from(r as Map);
          if (m['accepted'] == true) return PublishOutcome.sent;
          return switch (m['reason']) {
            'throttled' => PublishOutcome.throttled,
            'driver_fallback_disabled' => PublishOutcome.fallbackDisabled,
            _ => PublishOutcome.failed,
          };
        } catch (e) {
          return '$e'.contains('Not authorized') ? PublishOutcome.notAuthorized : PublishOutcome.failed;
        }
      },
      onStopped: (reason) {
        if (!mounted) return;
        _turnOff(switch (reason) {
          PublishOutcome.fallbackDisabled => 'Phone location sharing is not enabled for this bus. Ask thirty8 to enable the driver-phone fallback.',
          PublishOutcome.notAuthorized => 'You are not allowed to share location for this trip.',
          _ => 'GPS stopped. Turn sharing on again.',
        });
      },
    )..start();
    setState(() {
      _on = true;
      _message = null;
    });
  }

  void _turnOff([String? message]) {
    _publisher?.stop();
    _publisher = null;
    if (mounted) {
      setState(() {
        _on = false;
        _message = message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final allowed = phoneSharingAllowed(widget.tripStatus);
    final theme = Theme.of(context);
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Share this phone’s location'),
          subtitle: Text(allowed
              ? (_on ? 'Sharing while the app is open. Keep this screen on.' : 'Use only if the bus has no working GPS tracker.')
              : 'Available once the trip is boarding or departed.'),
          value: _on,
          onChanged: allowed ? (v) => v ? _turnOn() : _turnOff() : null,
        ),
        if (_message != null) Text(_message!, style: theme.textTheme.bodySmall?.copyWith(color: AppColors.warning)),
      ]),
    );
  }
}
