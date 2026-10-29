import 'package:flutter/services.dart';

/// Native-only operations; financial commands always go through the engine.
class WindowsPlatform {
  const WindowsPlatform({
    this.channel = const MethodChannel('ci.khoga.shopikaiss/windows'),
  });
  final MethodChannel channel;

  Future<String> dataDirectory() async =>
      (await channel.invokeMethod<String>('dataDirectory'))!;

  Future<Uint8List> protect(Uint8List bytes) async =>
      (await channel.invokeMethod<Uint8List>('protect', bytes))!;

  Future<Uint8List> unprotect(Uint8List bytes) async =>
      (await channel.invokeMethod<Uint8List>('unprotect', bytes))!;
}
