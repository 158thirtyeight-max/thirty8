import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:operator_app/features/tracking/phone_location_card.dart';
import 'package:operator_app/features/tracking/phone_location_publisher.dart';

PhoneFix fix(int seconds, {double lat = 12.0, double lng = 92.0}) =>
    PhoneFix(latitude: lat, longitude: lng, at: DateTime(2026, 10, 8, 12).add(Duration(seconds: seconds)));

void main() {
  late StreamController<PhoneFix> stream;
  late List<PhoneFix> sent;
  late PublishOutcome outcome;
  late List<PublishOutcome?> stopped;
  late PhoneLocationPublisher pub;

  setUp(() {
    stream = StreamController<PhoneFix>();
    sent = [];
    stopped = [];
    outcome = PublishOutcome.sent;
    pub = PhoneLocationPublisher(
      positions: () => stream.stream,
      send: (f) async {
        sent.add(f);
        return outcome;
      },
      onStopped: stopped.add,
    );
  });

  tearDown(() async {
    await pub.stop();
    unawaited(stream.close());
  });

  Future<void> push(PhoneFix f) async {
    stream.add(f);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  test('nothing is read or sent until start()', () async {
    await push(fix(0));
    expect(sent, isEmpty);
    expect(pub.running, isFalse);
  });

  test('first fix is sent; small moves inside the interval are not', () async {
    pub.start();
    await push(fix(0));
    await push(fix(3, lat: 12.001)); // far enough but too soon
    await push(fix(12, lat: 12.00005)); // late enough but only ~5 m
    expect(sent.length, 1);
  });

  test('moving at least 25 m after 10 s is sent', () async {
    pub.start();
    await push(fix(0));
    await push(fix(11, lat: 12.0005)); // ~55 m
    expect(sent.length, 2);
  });

  test('a standing bus sends a heartbeat every minute so it does not look offline', () async {
    pub.start();
    await push(fix(0));
    await push(fix(30));
    expect(sent.length, 1);
    await push(fix(61));
    expect(sent.length, 2);
  });

  test('the 0,0 "no fix" value is never sent', () async {
    pub.start();
    await push(fix(0, lat: 0, lng: 0));
    expect(sent, isEmpty);
  });

  test('stops itself when the bus has phone sharing disabled', () async {
    outcome = PublishOutcome.fallbackDisabled;
    pub.start();
    await push(fix(0));
    expect(pub.running, isFalse);
    expect(stopped, [PublishOutcome.fallbackDisabled]);
    await push(fix(100));
    expect(sent.length, 1);
  });

  test('a failed send (offline) keeps listening and retries on the next fix', () async {
    outcome = PublishOutcome.failed;
    pub.start();
    await push(fix(0));
    expect(pub.running, isTrue);
    outcome = PublishOutcome.sent;
    await push(fix(1));
    expect(sent.length, 2);
  });

  test('stop() ends sending', () async {
    pub.start();
    await push(fix(0));
    await pub.stop();
    await push(fix(100, lat: 13));
    expect(sent.length, 1);
  });

  test('sharing is only allowed for a running trip', () {
    expect(phoneSharingAllowed('scheduled'), isFalse);
    expect(phoneSharingAllowed('boarding'), isTrue);
    expect(phoneSharingAllowed('departed'), isTrue);
    expect(phoneSharingAllowed('arrived'), isFalse);
    expect(phoneSharingAllowed('cancelled'), isFalse);
  });
}
