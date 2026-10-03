import 'package:customer_app/features/booking/booking_errors.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a seat taken by another passenger gets the required message', () {
    expect(
      seatHoldErrorMessage(Exception('seat_unavailable: one or more selected seats are no longer available')),
      'This seat has just been reserved by another passenger. Please select another seat.',
    );
  });

  test('other hold errors are specific, never a false success', () {
    expect(seatHoldErrorMessage(Exception('trip_closed: x')), contains('closed'));
    expect(seatHoldErrorMessage(Exception('bus_unavailable')), contains('no longer available'));
    expect(seatHoldErrorMessage(Exception('invalid_points')), contains('boarding'));
    expect(seatHoldErrorMessage(Exception('boom')), contains('Could not hold'));
  });

  test('booking errors distinguish expiry, reuse and fare changes', () {
    expect(bookingErrorMessage(Exception('Hold has expired'), holdExpired: false), contains('expired'));
    expect(bookingErrorMessage(Exception('anything'), holdExpired: true), contains('expired'));
    expect(bookingErrorMessage(Exception('hold_already_used'), holdExpired: false), contains('already'));
    expect(bookingErrorMessage(Exception('trip_closed: x'), holdExpired: false), contains('closed'));
    expect(bookingErrorMessage(Exception('fare_changed'), holdExpired: false), contains('fare changed'));
    expect(bookingErrorMessage(Exception('points_changed'), holdExpired: false), contains('point'));
  });

  test('renewal errors explain why', () {
    expect(renewHoldErrorMessage(Exception('renewal_not_allowed: x')), contains('already been extended'));
    expect(renewHoldErrorMessage(Exception('hold_expired: Hold has expired')), contains('expired'));
  });
}
