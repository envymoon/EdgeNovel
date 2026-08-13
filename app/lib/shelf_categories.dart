import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ShelfCategories extends ChangeNotifier {
  ShelfCategories._();

  static final instance = ShelfCategories._();

  SharedPreferences? _prefs;
  final List<String> _names = [];
  final Map<String, String> _bookCategories = {};

  List<String> get names => List.unmodifiable(_names);

  Future<void> initialize() async {
    _prefs = await SharedPreferences.getInstance();
    _names
      ..clear()
      ..addAll(_prefs?.getStringList('shelfCategories') ?? const []);
    final raw = _prefs?.getString('shelfBookCategories');
    if (raw != null && raw.isNotEmpty) {
      try {
        final values = jsonDecode(raw) as Map<String, dynamic>;
        _bookCategories
          ..clear()
          ..addAll(values.map((key, value) => MapEntry(key, value as String)));
      } catch (_) {
        _bookCategories.clear();
      }
    }
  }

  String? categoryFor(Object bookId) => _bookCategories['$bookId'];

  bool add(String value) {
    final name = value.trim();
    if (name.isEmpty || _names.contains(name)) return false;
    _names.add(name);
    _persist();
    notifyListeners();
    return true;
  }

  bool rename(String oldName, String value) {
    final name = value.trim();
    final index = _names.indexOf(oldName);
    if (index < 0 ||
        name.isEmpty ||
        (name != oldName && _names.contains(name))) {
      return false;
    }
    _names[index] = name;
    for (final key in _bookCategories.keys.toList()) {
      if (_bookCategories[key] == oldName) _bookCategories[key] = name;
    }
    _persist();
    notifyListeners();
    return true;
  }

  void delete(String name) {
    _names.remove(name);
    _bookCategories.removeWhere((_, value) => value == name);
    _persist();
    notifyListeners();
  }

  void setForBook(Object bookId, String? category) {
    final key = '$bookId';
    if (category == null || !_names.contains(category)) {
      _bookCategories.remove(key);
    } else {
      _bookCategories[key] = category;
    }
    _persist();
    notifyListeners();
  }

  void removeBook(Object bookId) {
    if (_bookCategories.remove('$bookId') != null) {
      _persist();
      notifyListeners();
    }
  }

  void _persist() {
    _prefs?.setStringList('shelfCategories', _names);
    _prefs?.setString('shelfBookCategories', jsonEncode(_bookCategories));
  }
}
