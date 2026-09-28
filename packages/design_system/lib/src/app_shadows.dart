import 'package:flutter/material.dart';

/// Elevation/shadow scale. Mirrors `design-system/tokens.json` → `shadows`.
/// Soft, purple-tinted shadows — never a plain black box-shadow.
class AppShadows {
  AppShadows._();

  static const none = <BoxShadow>[];

  static const sm = <BoxShadow>[
    BoxShadow(color: Color(0x0F4C1D95), offset: Offset(0, 1), blurRadius: 2),
  ];

  static const md = <BoxShadow>[
    BoxShadow(color: Color(0x1A4C1D95), offset: Offset(0, 4), blurRadius: 12),
  ];

  static const lg = <BoxShadow>[
    BoxShadow(color: Color(0x244C1D95), offset: Offset(0, 12), blurRadius: 32),
  ];
}
