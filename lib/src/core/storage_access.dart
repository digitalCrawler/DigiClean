import 'dart:io';

import 'package:flutter/services.dart';

enum AccessState {
  /// Full access to shared storage (or not applicable on this platform).
  granted,
  denied,

  /// The user must enable access in system settings.
  permanentlyDenied,
}

/// Storage permission handling per platform:
///
/// * Android 11+ — "All files access" (`MANAGE_EXTERNAL_STORAGE`) is
///   required to read and delete arbitrary files in shared storage. It is
///   granted on a system settings screen.
/// * Android 10 and older — runtime `READ/WRITE_EXTERNAL_STORAGE`.
/// * iOS — no global permission; access is granted per folder through the
///   document picker.
/// * Desktop — governed by normal file-system permissions.
///
/// Implemented in `MainActivity.kt` over the `digiclean/platform` channel.
class StorageAccess {
  StorageAccess._();

  static const _channel = MethodChannel('digiclean/platform');

  static bool get needsPermission => Platform.isAndroid;

  static AccessState _parse(String? s) => switch (s) {
    'granted' => AccessState.granted,
    'permanentlyDenied' => AccessState.permanentlyDenied,
    _ => AccessState.denied,
  };

  static Future<AccessState> status() async {
    if (!needsPermission) return AccessState.granted;
    try {
      return _parse(await _channel.invokeMethod<String>('storageAccessStatus'));
    } on PlatformException {
      return AccessState.denied;
    }
  }

  /// Requests access and completes when the user returns from the system
  /// dialog or settings screen.
  static Future<AccessState> request() async {
    if (!needsPermission) return AccessState.granted;
    try {
      return _parse(await _channel.invokeMethod<String>('requestStorageAccess'));
    } on PlatformException {
      return status();
    }
  }

  static Future<void> openSettings() async {
    if (Platform.isAndroid) await _channel.invokeMethod<void>('openAppSettings');
  }

  /// Lets the scan service show its progress notification (Android 13+).
  static Future<void> requestNotifications() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('requestNotifications');
    } on PlatformException {
      // Scanning works without the notification.
    }
  }
}
