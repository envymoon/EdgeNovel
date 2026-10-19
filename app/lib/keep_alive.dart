import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';

import 'platform_services.dart';

/// iOS keeps an app behind the screen running only while it plays something.
/// Work that goes on there with 锁屏/后台运行 on — 提前合成, the AI queue —
/// plays silence for as long as it runs, starting while the app is still on
/// screen: iOS does not let it start from behind.
class SilentKeepAlive {
  /// Under other apps' sound rather than in place of it (the AI queue, which
  /// is not listened to); back to the usual when it stops. iOS has one sound
  /// setting for the whole app.
  final bool mix;

  SilentKeepAlive({this.mix = false});

  AudioPlayer? _player;
  bool _on = false;

  /// Playing now.
  bool get on => _on;

  /// True when this changed whether it plays.
  Future<bool> set(bool wanted) async {
    if (wanted == _on) return false;
    _on = wanted;
    try {
      if (!wanted) {
        await _player?.stop();
        if (mix) {
          await AudioPlayer.global.setAudioContext(
            AudioContextConfig().build(),
          );
        }
        return true;
      }
      if (mix) {
        await AudioPlayer.global.setAudioContext(
          AudioContextConfig(
            focus: AudioContextConfigFocus.mixWithOthers,
          ).build(),
        );
      }
      final player = _player ??= AudioPlayer();
      await player.setReleaseMode(ReleaseMode.loop);
      await player.play(DeviceFileSource(await _silenceFile()));
    } catch (_) {
      _on = false;
    }
    return _on == wanted;
  }

  /// A second of 24 kHz 16-bit mono, all zeros.
  static Future<String> _silenceFile() async {
    final dir = AppServices.instance.storage.temporaryChild('tts_keep');
    await dir.create(recursive: true);
    final file = File('${dir.path}${Platform.pathSeparator}silence.wav');
    if (!await file.exists()) {
      List<int> le32(int v) => [for (final s in [0, 8, 16, 24]) (v >> s) & 0xff];
      final wav = BytesBuilder()
        ..add('RIFF'.codeUnits)
        ..add(le32(36 + 48000))
        ..add('WAVEfmt '.codeUnits)
        ..add(le32(16))
        ..add([1, 0, 1, 0])
        ..add(le32(24000))
        ..add(le32(48000))
        ..add([2, 0, 16, 0])
        ..add('data'.codeUnits)
        ..add(le32(48000))
        ..add(Uint8List(48000));
      await file.writeAsBytes(wav.takeBytes(), flush: true);
    }
    return file.path;
  }
}
