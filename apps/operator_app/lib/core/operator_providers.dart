import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'supabase_providers.dart';

class OperatorContext {
  OperatorContext({required this.role, required this.operator});

  final String role;
  final Map<String, dynamic> operator;

  String get operatorId => operator['id'] as String;
  String get businessType => operator['business_type'] as String;
  String get status => operator['status'] as String;
  bool get isApproved => status == 'approved';
  bool get servesBus => businessType == 'bus' || businessType == 'both';
  bool get servesCargo => businessType == 'cargo' || businessType == 'both';
  bool get isAdmin => role == 'operator_admin';
}

/// Null means the current user has no operator_staff/operator_admin role yet
/// (they need to register an operator, or wait for an invite).
final operatorContextProvider = FutureProvider<OperatorContext?>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return null;

  final supabase = ref.watch(supabaseProvider);
  final roleRow = await supabase
      .from('user_roles')
      .select('role, operator_id')
      .eq('user_id', user.id)
      .inFilter('role', ['operator_admin', 'operator_staff', 'driver', 'conductor'])
      .maybeSingle();

  if (roleRow == null || roleRow['operator_id'] == null) return null;

  final operatorRow = await supabase
      .from('operators')
      .select()
      .eq('id', roleRow['operator_id'] as String)
      .single();

  return OperatorContext(role: roleRow['role'] as String, operator: operatorRow);
});
