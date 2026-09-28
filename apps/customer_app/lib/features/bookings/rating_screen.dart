import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/supabase_providers.dart';

class RatingScreen extends ConsumerStatefulWidget {
  const RatingScreen({super.key, required this.tripId});

  final String tripId;

  @override
  ConsumerState<RatingScreen> createState() => _RatingScreenState();
}

class _RatingScreenState extends ConsumerState<RatingScreen> {
  int _rating = 0;
  final _reviewController = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _reviewController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_rating == 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please select a star rating')));
      return;
    }
    setState(() => _submitting = true);
    try {
      final userId = ref.read(currentUserProvider)!.id;
      await ref.read(supabaseProvider).from('ratings_reviews').insert({
        'profile_id': userId,
        'trip_id': widget.tripId,
        'rating': _rating,
        'review': _reviewController.text.trim().isEmpty ? null : _reviewController.text.trim(),
      });
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Thanks for your feedback!')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not submit your rating')));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Rate your trip')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(5, (i) {
                  final starIndex = i + 1;
                  return IconButton(
                    iconSize: 40,
                    icon: Icon(
                      starIndex <= _rating ? Icons.star : Icons.star_border,
                      color: AppColors.accent,
                    ),
                    onPressed: () => setState(() => _rating = starIndex),
                  );
                }),
              ),
              const SizedBox(height: 24),
              AppTextField(
                controller: _reviewController,
                label: 'Tell us more (optional)',
                maxLines: 4,
              ),
              const SizedBox(height: 24),
              AppButton(
                label: 'Submit rating',
                loading: _submitting,
                onPressed: _submitting ? null : _submit,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
