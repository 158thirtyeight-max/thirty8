import 'package:flutter/material.dart';

/// Semantic color tokens. Mirrors `design-system/tokens.json` → `colors`.
/// Never reference a raw `Color(0xFF...)` outside this file — add a token
/// here instead, so every screen and both Flutter apps stay in sync.
class AppColors {
  AppColors._();

  static const primary = Color(0xFF6D28D9);
  static const primaryDark = Color(0xFF4C1D95);
  static const primaryLight = Color(0xFFC4B5FD);
  static const secondary = Color(0xFF4F46E5);
  static const accent = Color(0xFFF59E0B);

  static const background = Color(0xFFF8F7FC);
  static const backgroundDark = Color(0xFF0B0712);
  static const surface = Color(0xFFFFFFFF);
  static const surfaceDark = Color(0xFF150F23);
  static const surfaceElevated = Color(0xFFFFFFFF);
  static const surfaceElevatedDark = Color(0xFF1D1530);
  static const card = Color(0xFFFFFFFF);
  static const cardDark = Color(0xFF1D1530);

  static const textPrimary = Color(0xFF1E1B2E);
  static const textPrimaryDark = Color(0xFFF5F3FA);
  static const textSecondary = Color(0xFF615C73);
  static const textSecondaryDark = Color(0xFFB3ACC6);
  static const textTertiary = Color(0xFF9B96AC);
  static const textTertiaryDark = Color(0xFF7C7690);

  static const border = Color(0xFFE7E3F0);
  static const borderDark = Color(0xFF2D2542);
  static const divider = Color(0xFFEFECF7);
  static const dividerDark = Color(0xFF251D3A);

  static const success = Color(0xFF10B981);
  static const warning = Color(0xFFF59E0B);
  static const error = Color(0xFFEF4444);
  static const info = Color(0xFF3B82F6);
  static const disabled = Color(0xFFC9C5D6);
  static const disabledDark = Color(0xFF4A4460);
}
