import 'package:flutter/material.dart';

import 'presentation/register_app.dart';
import 'presentation/bootstrap.dart';

/// Dedicated target until B integrates the real engine bootstrap.
/// No demo data, credentials, remote WebView or simulated successful sale.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const bool.fromEnvironment('SHOPIKAISS_WINDOWS_REVIEW_ENGINE')
        ? const WindowsBootstrap()
        : const WindowsRegisterApp(),
  );
}
