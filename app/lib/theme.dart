import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'tts_remote.dart';

/// A reading theme is a background *and* the text colour tuned for it. Pairing a
/// warm background with pure black text, or an OLED black with pure white, is
/// what makes most readers' "eye care" modes uncomfortable: the contrast is
/// either too low to read or high enough to bloom.
class ReadingTheme {
  final String name;
  final Color background;
  final Color text;
  final Color muted;

  const ReadingTheme(this.name, this.background, this.text, this.muted);

  bool get isDark => background.computeLuminance() < 0.4;
}

const readingThemes = <ReadingTheme>[
  ReadingTheme('纸白', Color(0xFFF7F7F5), Color(0xFF1C1C1E), Color(0xFF8E8E93)),
  ReadingTheme('米黄', Color(0xFFF5EFDF), Color(0xFF3B3226), Color(0xFF938A78)),
  ReadingTheme('护眼绿', Color(0xFFCCE8CF), Color(0xFF2C3A2E), Color(0xFF6B7D6E)),
  ReadingTheme('夜间', Color(0xFF1C1C1E), Color(0xFFC9C9CE), Color(0xFF6E6E73)),
  ReadingTheme('纯黑', Color(0xFF000000), Color(0xFFB0B0B5), Color(0xFF5A5A5F)),
];

enum PageMode { scroll, paged }

class ReadingSettings extends ChangeNotifier {
  int themeIndex = 1;
  String fontFamily = '';
  double fontSize = 19;
  double lineHeight = 1.9;
  double paragraphSpacing = 14;
  bool firstLineIndent = true;
  PageMode pageMode = PageMode.scroll;
  double pageWidth = 720;

  /// Read-aloud pace, 1.0 = the voice's natural speed. Persisted so a chosen
  /// pace survives across books and sessions.
  double ttsSpeed = 1.0;

  /// Read-aloud goes to a server the user runs elsewhere (see `tts_remote.dart`)
  /// rather than to the small engine bundled here. Off until they set an address
  /// up, and turned on for them the moment they do — nobody configures a server
  /// and then means for it not to be used.
  bool ttsRemote = false;
  String ttsServerUrl = '';
  String ttsServerKey = '';
  String ttsServerModel = '';

  /// Voice name as the *server* names it. Free text: which names are valid is
  /// the server's business, not ours.
  String ttsServerVoice = '';

  /// Speaker id for the bundled local engine, used when [ttsRemote] is off.
  int ttsLocalVoice = 49;

  TtsServer get ttsServer => TtsServer(
    baseUrl: ttsServerUrl,
    apiKey: ttsServerKey,
    model: ttsServerModel,
  );

  SharedPreferences? _prefs;

  ReadingTheme get theme => readingThemes[themeIndex];

  /// Restore what the reader chose last time. Losing the font size on every
  /// restart is the kind of friction this app exists to remove.
  static Future<ReadingSettings> load() async {
    final s = ReadingSettings();
    final p = await SharedPreferences.getInstance();
    s._prefs = p;
    s.themeIndex = (p.getInt('themeIndex') ?? s.themeIndex).clamp(
      0,
      readingThemes.length - 1,
    );
    s.fontFamily = p.getString('fontFamily') ?? s.fontFamily;
    s.fontSize = p.getDouble('fontSize') ?? s.fontSize;
    s.lineHeight = p.getDouble('lineHeight') ?? s.lineHeight;
    s.paragraphSpacing = p.getDouble('paragraphSpacing') ?? s.paragraphSpacing;
    s.firstLineIndent = p.getBool('firstLineIndent') ?? s.firstLineIndent;
    s.pageMode =
        PageMode.values[(p.getInt('pageMode') ?? 0).clamp(
          0,
          PageMode.values.length - 1,
        )];
    s.pageWidth = p.getDouble('pageWidth') ?? s.pageWidth;
    s.ttsSpeed = p.getDouble('ttsSpeed') ?? s.ttsSpeed;
    s.ttsLocalVoice = p.getInt('ttsVoice') ?? s.ttsLocalVoice;
    s.ttsServerUrl = p.getString('ttsServerUrl') ?? s.ttsServerUrl;
    s.ttsServerKey = p.getString('ttsServerKey') ?? s.ttsServerKey;
    s.ttsServerModel = p.getString('ttsServerModel') ?? s.ttsServerModel;
    s.ttsServerVoice = p.getString('ttsServerVoice') ?? s.ttsServerVoice;
    s.ttsRemote =
        (p.getBool('ttsRemote') ?? false) && s.ttsServerUrl.isNotEmpty;
    return s;
  }

  void _persist() {
    final p = _prefs;
    if (p == null) return;
    p.setInt('themeIndex', themeIndex);
    p.setString('fontFamily', fontFamily);
    p.setDouble('fontSize', fontSize);
    p.setDouble('lineHeight', lineHeight);
    p.setDouble('paragraphSpacing', paragraphSpacing);
    p.setBool('firstLineIndent', firstLineIndent);
    p.setInt('pageMode', pageMode.index);
    p.setDouble('pageWidth', pageWidth);
    p.setDouble('ttsSpeed', ttsSpeed);
    p.setInt('ttsVoice', ttsLocalVoice);
    p.setBool('ttsRemote', ttsRemote);
    p.setString('ttsServerUrl', ttsServerUrl);
    p.setString('ttsServerKey', ttsServerKey);
    p.setString('ttsServerModel', ttsServerModel);
    p.setString('ttsServerVoice', ttsServerVoice);
  }

  void setTtsLocalVoice(int sid) {
    ttsLocalVoice = sid;
    notifyListeners();
    _persist();
  }

  void setTtsRemote(bool on) {
    ttsRemote = on && ttsServerUrl.trim().isNotEmpty;
    notifyListeners();
    _persist();
  }

  /// Saving an address is itself the decision to use it.
  void setTtsServer({String? url, String? key, String? model, String? voice}) {
    if (url != null) ttsServerUrl = url.trim();
    if (key != null) ttsServerKey = key.trim();
    if (model != null) ttsServerModel = model.trim();
    if (voice != null) ttsServerVoice = voice.trim();
    if (ttsServerUrl.isEmpty) {
      ttsRemote = false;
    } else if (url != null) {
      ttsRemote = true;
    }
    notifyListeners();
    _persist();
  }

  void setTtsSpeed(double v) {
    ttsSpeed = v.clamp(0.5, 2.0);
    notifyListeners();
    _persist();
  }

  void setTheme(int i) {
    themeIndex = i.clamp(0, readingThemes.length - 1);
    notifyListeners();
    _persist();
  }

  void setFontSize(double v) {
    fontSize = v.clamp(12, 34);
    notifyListeners();
    _persist();
  }

  void setFontFamily(String family) {
    fontFamily = family;
    notifyListeners();
    _persist();
  }

  void setLineHeight(double v) {
    lineHeight = v.clamp(1.2, 2.6);
    notifyListeners();
    _persist();
  }

  void setParagraphSpacing(double v) {
    paragraphSpacing = v.clamp(0, 32);
    notifyListeners();
    _persist();
  }

  void setFirstLineIndent(bool v) {
    firstLineIndent = v;
    notifyListeners();
    _persist();
  }

  void setPageMode(PageMode m) {
    pageMode = m;
    notifyListeners();
    _persist();
  }

  void setPageWidth(double v) {
    pageWidth = v.clamp(520, 1080);
    notifyListeners();
    _persist();
  }
}

/// The row of background swatches, shared by the reader's typography sheet and
/// the shelf's palette button. Both write to the same [ReadingSettings], so a
/// colour chosen on the shelf is already in force inside the book, and the other
/// way round — the sync is the shared object, not a copy. Listens to `settings`
/// itself so the ring lands on the current pick wherever it is shown.
class ThemeSwatches extends StatelessWidget {
  final ReadingSettings settings;

  const ThemeSwatches({super.key, required this.settings});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: settings,
      builder: (context, _) {
        final t = settings.theme;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (var i = 0; i < readingThemes.length; i++)
              GestureDetector(
                onTap: () => settings.setTheme(i),
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: readingThemes[i].background,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: i == settings.themeIndex
                          ? t.text
                          : t.muted.withValues(alpha: 0.3),
                      width: i == settings.themeIndex ? 2 : 1,
                    ),
                  ),
                  child: Center(
                    child: Text(
                      '文',
                      style: TextStyle(
                        color: readingThemes[i].text,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
