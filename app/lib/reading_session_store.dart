import 'package:shared_preferences/shared_preferences.dart';

/// Remembers only whether the reader itself was open. Book position, chapter
/// completion, annotations and AI checkpoints remain in the main database.
class ReadingSessionStore {
  ReadingSessionStore(this._preferences);

  static const _activeBookPathKey = 'reader.activeBookPath.v1';
  final SharedPreferences _preferences;

  static Future<ReadingSessionStore> load() async =>
      ReadingSessionStore(await SharedPreferences.getInstance());

  String? get activeBookPath {
    final value = _preferences.getString(_activeBookPathKey)?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  Future<void> remember(String path) async {
    await _preferences.setString(_activeBookPathKey, path);
  }

  Future<void> clear() async {
    await _preferences.remove(_activeBookPathKey);
  }
}
