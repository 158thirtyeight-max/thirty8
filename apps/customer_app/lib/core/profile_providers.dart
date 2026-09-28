import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'supabase_providers.dart';

/// Null means the profile has no full_name or no phone yet — this happens
/// for Google OAuth sign-ins (Google never gives us a phone number) and is
/// the signal the router uses to force a stop at /complete-profile before
/// letting the user into the app, since phone + name are required for
/// ticketing (contact details on bookings/shipments).
final myProfileProvider = FutureProvider.autoDispose<Map<String, dynamic>?>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return null;

  final supabase = ref.watch(supabaseProvider);
  return await supabase.from('profiles').select('id, full_name, phone, email').eq('id', user.id).maybeSingle();
});

final profileIsCompleteProvider = FutureProvider.autoDispose<bool>((ref) async {
  final profile = await ref.watch(myProfileProvider.future);
  if (profile == null) return false;
  final fullName = profile['full_name'] as String?;
  final phone = profile['phone'] as String?;
  return fullName != null && fullName.trim().isNotEmpty && phone != null && phone.trim().isNotEmpty;
});
