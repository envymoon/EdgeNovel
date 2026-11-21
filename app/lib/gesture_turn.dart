import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 隔空翻页: the front camera watched by the phone's own face and hand
/// recognition (AppDelegate.swift, GestureWatch). Nothing is downloaded and
/// nothing is kept; the camera runs only while a reader or the settings page
/// asks for it.
class GestureTurn {
  GestureTurn._() {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'gesture':
          final name = call.arguments as String;
          last.value = (name, DateTime.now());
          for (final f in [..._listeners]) {
            f(name);
          }
        case 'seen':
          final m = Map<String, dynamic>.from(call.arguments as Map);
          seen.value = (m['face'] == true, m['hand'] == true);
      }
    });
  }

  static final instance = GestureTurn._();
  static const _channel = MethodChannel('novel/gesture');

  /// iPhone only for now.
  static bool get available =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  /// What each name is called, in the order they are offered.
  static const names = <String, String>{
    'turnLeft': '向左转头',
    'turnRight': '向右转头',
    'nod': '点头',
    'winkLeft': '眨左眼',
    'winkRight': '眨右眼',
    'blink': '闭眼一下',
    'swipeLeft': '向左挥手',
    'swipeRight': '向右挥手',
  };

  final _listeners = <void Function(String)>{};

  /// The last gesture seen, and when.
  final last = ValueNotifier<(String, DateTime)?>(null);

  /// Whether a face and a hand are in view, said twice a second.
  final seen = ValueNotifier<(bool, bool)>((false, false));

  var _users = 0;

  /// Start the camera for one more user; the reason it would not, or null.
  Future<String?> start() async {
    if (!available) return '此设备暂不支持';
    _users++;
    try {
      await _channel.invokeMethod('start');
      return null;
    } on PlatformException catch (e) {
      _users--;
      return e.message ?? '相机打不开';
    }
  }

  /// One user is done; the camera stops when none is left.
  Future<void> stop() async {
    if (_users == 0) return;
    _users--;
    if (_users > 0) return;
    seen.value = (false, false);
    try {
      await _channel.invokeMethod('stop');
    } on PlatformException {
      // Already stopped.
    }
  }

  void Function() listen(void Function(String) f) {
    _listeners.add(f);
    return () => _listeners.remove(f);
  }
}
