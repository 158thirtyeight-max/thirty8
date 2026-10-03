/// Turns backend booking errors into messages a customer can act on.
/// The server raises plain exceptions whose message starts with a stable code
/// (`seat_unavailable: ...`), so we match on the code prefix.
library;

const seatTakenMessage = 'This seat has just been reserved by another passenger. Please select another seat.';

String seatHoldErrorMessage(Object error) {
  final text = error.toString();
  if (text.contains('seat_unavailable')) return seatTakenMessage;
  if (text.contains('trip_closed')) return 'Bookings for this trip have closed.';
  if (text.contains('bus_unavailable')) return 'This bus is no longer available for booking.';
  if (text.contains('invalid_points')) return 'Please choose a valid boarding and dropping point.';
  return 'Could not hold those seats. Please try again.';
}

String bookingErrorMessage(Object error, {required bool holdExpired}) {
  final text = error.toString();
  if (holdExpired || text.contains('Hold has expired') || text.contains('hold_expired')) {
    return 'Your seat hold expired. Please select your seats again.';
  }
  if (text.contains('document_required')) return 'Every passenger needs an ID type and number.';
  if (text.contains('invalid_document')) return 'One of the ID numbers is not valid. Please check it and try again.';
  if (text.contains('hold_already_used')) return 'These seats are already part of a booking.';
  if (text.contains('trip_closed')) return 'Bookings for this trip have closed.';
  if (text.contains('fare_changed')) return 'The fare changed since you selected your seats. Please go back and review the price.';
  if (text.contains('points_changed')) return 'The boarding or dropping point changed. Please go back and choose again.';
  if (text.contains('bus_unavailable')) return 'This bus is no longer available for booking.';
  return 'Could not create the booking. Please try again.';
}

String renewHoldErrorMessage(Object error) {
  final text = error.toString();
  if (text.contains('renewal_not_allowed')) return 'This hold has already been extended and cannot be extended again.';
  if (text.contains('hold_expired') || text.contains('Hold has expired')) return 'Your seat hold has expired. Please select your seats again.';
  if (text.contains('trip_closed')) return 'Bookings for this trip have closed.';
  return 'Could not extend your hold. Please try again.';
}
