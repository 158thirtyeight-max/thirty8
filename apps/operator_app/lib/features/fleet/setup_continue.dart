import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';

/// Result a bus-setup section pops with when the operator chose to carry on: the setup hub then opens
/// the next section, so every section ends the same way.
const kSetupContinue = 'setup:continue';

const setupContinueLabel = 'Save & Continue to Next Section';

/// The one button every bus-setup section ends with.
class SetupContinueButton extends StatelessWidget {
  const SetupContinueButton({super.key, required this.onPressed, this.loading = false});

  final VoidCallback? onPressed;
  final bool loading;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: AppSpacing.md),
        child: AppButton(label: setupContinueLabel, expand: true, loading: loading, onPressed: loading ? null : onPressed),
      );
}

/// Shows the system time picker in 24-hour format, regardless of the device's 12/24h setting.
Future<TimeOfDay?> pick24HourTime(BuildContext context, {required int? minutes, int fallback = 360}) {
  final m = minutes ?? fallback;
  return showTimePicker(
    context: context,
    initialTime: TimeOfDay(hour: (m ~/ 60) % 24, minute: m % 60),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
      child: child!,
    ),
  );
}
