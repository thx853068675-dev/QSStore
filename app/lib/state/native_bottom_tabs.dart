// Copyright QuietStart contributors. SPDX-License-Identifier: MIT

import 'dart:io';

import 'package:flutter/services.dart';

/// Synchronizes the Flutter page with HarmonyOS's native HdsTabs bar.
class NativeBottomTabs {
  NativeBottomTabs._();

  static const _channel = MethodChannel('qingqi/native_bottom_tabs');
  static bool get isSupported => Platform.operatingSystem == 'ohos';

  static bool _shellVisible = false;
  static bool _rootRoute = true;
  static int _index = 0;
  static void Function(int)? _onSelected;

  static void initialize() {
    if (!isSupported) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'navigationTap' && call.arguments is int) {
        _onSelected?.call(call.arguments as int);
      }
    });
  }

  static void attach(void Function(int) onSelected) {
    _onSelected = onSelected;
    _shellVisible = true;
    _sync();
  }

  static void detach() {
    _shellVisible = false;
    _onSelected = null;
    _sync();
  }

  static void routeAtRoot(bool value) {
    _rootRoute = value;
    _sync();
  }

  static void select(int index) {
    _index = index;
    _sync();
  }

  static void _sync() {
    if (!isSupported) return;
    // A navigation event can happen during teardown; the next attach resends
    // the complete state, so an unavailable platform channel is harmless.
    _channel.invokeMethod<void>('setNavigation', {
      'visible': _shellVisible && _rootRoute,
      'index': _index,
    }).catchError((Object _) {});
  }
}
