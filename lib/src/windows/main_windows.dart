import 'package:flutter/material.dart';

import 'presentation/register_app.dart';

/// Dedicated target until B integrates the real engine bootstrap.
/// No demo data, credentials, remote WebView or simulated successful sale.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const WindowsRegisterApp());
}
