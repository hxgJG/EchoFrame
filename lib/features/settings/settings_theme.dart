import 'package:flutter/material.dart';

class SettingsTheme extends StatelessWidget {
  const SettingsTheme({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    return Theme(
      data: theme.copyWith(
        textTheme: text.copyWith(
          titleLarge: text.titleLarge?.copyWith(fontSize: 18),
          titleMedium: text.titleMedium?.copyWith(fontSize: 14),
          bodyLarge: text.bodyLarge?.copyWith(fontSize: 14),
          bodyMedium: text.bodyMedium?.copyWith(fontSize: 12),
          labelLarge: text.labelLarge?.copyWith(fontSize: 12),
        ),
        appBarTheme: theme.appBarTheme.copyWith(
          titleTextStyle:
              theme.appBarTheme.titleTextStyle?.copyWith(fontSize: 18),
        ),
      ),
      child: child,
    );
  }
}
