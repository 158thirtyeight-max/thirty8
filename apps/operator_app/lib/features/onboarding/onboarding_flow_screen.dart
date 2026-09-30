import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/operator_providers.dart';
import '../../core/supabase_providers.dart';
import 'bank_step.dart';
import 'business_step.dart';
import 'kyc_step.dart';
import 'mandate_step.dart';
import 'review_step.dart';

const onboardingStepTitles = [
  'Business',
  'KYC & Tax',
  'Bank & Payout',
  'Payment Mandate',
  'Review',
  'Submit',
];

/// Multi-step operator registration (Phase 1 of onboarding). Shown by the gate
/// when the user has no operator yet, or the application is a draft / has
/// changes requested. Progress is saved per step and resumes at the furthest
/// step reached (operators.onboarding_step).
///
/// Steps 5-6 are the review summary and the submit action (RPC
/// submit_operator_application, which re-checks completeness server-side).
class OnboardingFlowScreen extends ConsumerStatefulWidget {
  const OnboardingFlowScreen({super.key, this.operatorContext});

  final OperatorContext? operatorContext;

  @override
  ConsumerState<OnboardingFlowScreen> createState() => _OnboardingFlowScreenState();
}

class _OnboardingFlowScreenState extends ConsumerState<OnboardingFlowScreen> {
  static const _implementedSteps = 6;

  late int _step; // 0-based
  String? _operatorId;

  @override
  void initState() {
    super.initState();
    final ctx = widget.operatorContext;
    _operatorId = ctx?.operatorId;
    final saved = (ctx?.onboardingStep ?? 1) - 1;
    // After a change request, land on the review summary so the operator sees
    // what to fix; otherwise resume at the furthest step reached.
    _step = ctx?.applicationStatus == 'changes_requested' ? 4 : saved.clamp(0, _implementedSteps - 1);
  }

  void _businessSaved(String operatorId, {required bool advance}) {
    setState(() {
      _operatorId = operatorId;
      if (advance) _step = 1;
    });
    ref.invalidate(operatorContextProvider);
  }

  void _stepSaved(int next, {required bool advance}) {
    if (advance) setState(() => _step = next);
    ref.invalidate(operatorContextProvider);
  }

  @override
  Widget build(BuildContext context) {
    final ctx = widget.operatorContext;
    final changesRequested = ctx?.applicationStatus == 'changes_requested';
    final shownStep = _step.clamp(0, onboardingStepTitles.length - 1);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Register your business'),
        actions: [
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
            onPressed: () => ref.read(supabaseProvider).auth.signOut(),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            _StepHeader(current: shownStep),
            if (changesRequested && (ctx?.reviewReason?.isNotEmpty ?? false))
              _ChangesBanner(reason: ctx!.reviewReason!),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    switch (_step) {
      case 0:
        return BusinessStep(
          key: ValueKey('business-${_operatorId ?? 'new'}'),
          operatorId: _operatorId,
          operator: widget.operatorContext?.operator,
          onSaved: _businessSaved,
        );
      case 1:
        return KycStep(
          operatorId: _operatorId!,
          businessType: (widget.operatorContext?.operator['business_type'] as String?) ?? 'bus',
          onBack: () => setState(() => _step = 0),
          onSaved: ({required advance}) => _stepSaved(2, advance: advance),
        );
      case 2:
        return BankStep(
          operatorId: _operatorId!,
          operator: widget.operatorContext?.operator ?? const {},
          onBack: () => setState(() => _step = 1),
          onSaved: ({required advance}) => _stepSaved(3, advance: advance),
        );
      case 3:
        return MandateStep(
          operatorId: _operatorId!,
          operator: widget.operatorContext?.operator ?? const {},
          onBack: () => setState(() => _step = 2),
          onSaved: ({required advance}) => _stepSaved(4, advance: advance),
        );
      case 4:
        return ReviewStep(
          operatorId: _operatorId!,
          operator: widget.operatorContext?.operator ?? const {},
          onBack: () => setState(() => _step = 3),
          onEditStep: (step) => setState(() => _step = step),
          onContinue: () => setState(() => _step = 5),
        );
      default:
        return SubmitStep(
          operatorId: _operatorId!,
          onBack: () => setState(() => _step = 4),
        );
    }
  }
}

class _StepHeader extends StatelessWidget {
  const _StepHeader({required this.current});
  final int current;

  @override
  Widget build(BuildContext context) {
    final total = onboardingStepTitles.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Step ${current + 1} of $total · ${onboardingStepTitles[current]}',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: AppSpacing.xs),
          LinearProgressIndicator(value: (current + 1) / total),
        ],
      ),
    );
  }
}

class _ChangesBanner extends StatelessWidget {
  const _ChangesBanner({required this.reason});
  final String reason;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, 0),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Changes requested', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: AppSpacing.xs),
            Text(reason),
          ],
        ),
      ),
    );
  }
}
