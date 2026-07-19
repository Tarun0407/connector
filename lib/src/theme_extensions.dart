import 'package:flutter/material.dart';

@immutable
class ConnectorColors extends ThemeExtension<ConnectorColors> {
  const ConnectorColors({
    required this.scaffoldBackground,
    required this.cardBorder,
    required this.bodyText,
    required this.firebaseWarningBackground,
    required this.firebaseWarningIcon,
    required this.firebaseWarningText,
    required this.disconnectedPanelBackground,
    required this.statusPillBorder,
    required this.onlineIcon,
    required this.emptyStateIcon,
  });

  final Color scaffoldBackground;
  final Color cardBorder;
  final Color bodyText;
  final Color firebaseWarningBackground;
  final Color firebaseWarningIcon;
  final Color firebaseWarningText;
  final Color disconnectedPanelBackground;
  final Color statusPillBorder;
  final Color onlineIcon;
  final Color emptyStateIcon;

  @override
  ConnectorColors copyWith({
    Color? scaffoldBackground,
    Color? cardBorder,
    Color? bodyText,
    Color? firebaseWarningBackground,
    Color? firebaseWarningIcon,
    Color? firebaseWarningText,
    Color? disconnectedPanelBackground,
    Color? statusPillBorder,
    Color? onlineIcon,
    Color? emptyStateIcon,
  }) {
    return ConnectorColors(
      scaffoldBackground: scaffoldBackground ?? this.scaffoldBackground,
      cardBorder: cardBorder ?? this.cardBorder,
      bodyText: bodyText ?? this.bodyText,
      firebaseWarningBackground: firebaseWarningBackground ?? this.firebaseWarningBackground,
      firebaseWarningIcon: firebaseWarningIcon ?? this.firebaseWarningIcon,
      firebaseWarningText: firebaseWarningText ?? this.firebaseWarningText,
      disconnectedPanelBackground: disconnectedPanelBackground ?? this.disconnectedPanelBackground,
      statusPillBorder: statusPillBorder ?? this.statusPillBorder,
      onlineIcon: onlineIcon ?? this.onlineIcon,
      emptyStateIcon: emptyStateIcon ?? this.emptyStateIcon,
    );
  }

  @override
  ConnectorColors lerp(ThemeExtension<ConnectorColors>? other, double t) {
    if (other is! ConnectorColors) {
      return this;
    }
    return ConnectorColors(
      scaffoldBackground: Color.lerp(scaffoldBackground, other.scaffoldBackground, t)!,
      cardBorder: Color.lerp(cardBorder, other.cardBorder, t)!,
      bodyText: Color.lerp(bodyText, other.bodyText, t)!,
      firebaseWarningBackground: Color.lerp(firebaseWarningBackground, other.firebaseWarningBackground, t)!,
      firebaseWarningIcon: Color.lerp(firebaseWarningIcon, other.firebaseWarningIcon, t)!,
      firebaseWarningText: Color.lerp(firebaseWarningText, other.firebaseWarningText, t)!,
      disconnectedPanelBackground: Color.lerp(disconnectedPanelBackground, other.disconnectedPanelBackground, t)!,
      statusPillBorder: Color.lerp(statusPillBorder, other.statusPillBorder, t)!,
      onlineIcon: Color.lerp(onlineIcon, other.onlineIcon, t)!,
      emptyStateIcon: Color.lerp(emptyStateIcon, other.emptyStateIcon, t)!,
    );
  }
}
