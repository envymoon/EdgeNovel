import 'package:flutter/material.dart';

class InterfaceTypography extends ThemeExtension<InterfaceTypography> {
  final bool uniform;
  const InterfaceTypography({required this.uniform});

  @override
  InterfaceTypography copyWith({bool? uniform}) =>
      InterfaceTypography(uniform: uniform ?? this.uniform);

  @override
  InterfaceTypography lerp(covariant InterfaceTypography? other, double t) =>
      t < 0.5 ? this : (other ?? this);
}
