import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists and broadcasts the user's chosen app seed color.
/// Call [load()] once at startup, then wrap [MyApp] with a [ListenableBuilder].
class AppThemeService extends ChangeNotifier {
  AppThemeService._();
  static final AppThemeService instance = AppThemeService._();

  static const _kSeedColorKey = 'app_seed_color';

  Color _seedColor = const Color(0xFF2196F3); // default: blue

  Color get seedColor => _seedColor;

  ThemeData get lightTheme => ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(seedColor: _seedColor),
  );

  ThemeData get darkTheme => ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: ColorScheme.fromSeed(
      seedColor: _seedColor,
      brightness: Brightness.dark,
    ),
  );

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getInt(_kSeedColorKey);
    if (value != null) {
      _seedColor = Color(value);
      notifyListeners();
    }
  }

  Future<void> setSeedColor(Color color) async {
    _seedColor = color;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kSeedColorKey, color.toARGB32());
  }

  /// Preset palette shown in the theme picker.
  static const List<({String label, Color color})> presets = [
    (label: 'Blue', color: Color(0xFF2196F3)),
    (label: 'Indigo', color: Color(0xFF3F51B5)),
    (label: 'Purple', color: Color(0xFF9C27B0)),
    (label: 'Pink', color: Color(0xFFE91E63)),
    (label: 'Red', color: Color(0xFFF44336)),
    (label: 'Orange', color: Color(0xFFFF9800)),
    (label: 'Teal', color: Color(0xFF009688)),
    (label: 'Green', color: Color(0xFF4CAF50)),
    (label: 'Cyan', color: Color(0xFF00BCD4)),
    (label: 'Brown', color: Color(0xFF795548)),
    (label: 'Slate', color: Color(0xFF607D8B)),
    (label: 'Deep Purple', color: Color(0xFF673AB7)),
  ];
}
