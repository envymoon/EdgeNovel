import 'dart:async';

import 'package:flutter/material.dart' hide Text;

import 'app_localizations.dart';
import 'gesture_turn.dart';
import 'theme.dart';

/// 隔空翻页: on or off, which gesture turns which way, and what the camera
/// sees right now, so the reader can try each gesture before picking.
class GestureTurnPage extends StatefulWidget {
  final ReadingSettings settings;

  const GestureTurnPage({super.key, required this.settings});

  @override
  State<GestureTurnPage> createState() => _GestureTurnPageState();
}

class _GestureTurnPageState extends State<GestureTurnPage> {
  String? _error;
  var _started = false;
  Timer? _fade;
  var _showing = false;

  @override
  void initState() {
    super.initState();
    GestureTurn.instance.last.addListener(_onGesture);
    unawaited(_start());
  }

  Future<void> _start() async {
    final failed = await GestureTurn.instance.start();
    if (!mounted) {
      if (failed == null) unawaited(GestureTurn.instance.stop());
      return;
    }
    setState(() {
      _error = failed;
      _started = failed == null;
    });
  }

  @override
  void dispose() {
    _fade?.cancel();
    GestureTurn.instance.last.removeListener(_onGesture);
    if (_started) unawaited(GestureTurn.instance.stop());
    super.dispose();
  }

  /// A gesture shows for two seconds.
  void _onGesture() {
    _fade?.cancel();
    _fade = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _showing = false);
    });
    if (mounted) setState(() => _showing = true);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    final t = s.theme;
    final last = GestureTurn.instance.last.value;
    final fresh = _showing && last != null;
    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        backgroundColor: t.background,
        surfaceTintColor: Colors.transparent,
        iconTheme: IconThemeData(color: t.muted),
        title: Text('隔空翻页', style: TextStyle(color: t.text, fontSize: 17)),
      ),
      body: ListenableBuilder(
        listenable: s,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            Container(
              height: 120,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: t.surface,
                border: Border.all(color: t.outline),
                borderRadius: BorderRadius.circular(14),
              ),
              child: _error != null
                  ? Text(
                      _error!,
                      style: const TextStyle(
                        color: Color(0xFFB3574D),
                        fontSize: 14,
                      ),
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          fresh ? GestureTurn.names[last.$1] ?? last.$1 : '—',
                          style: TextStyle(
                            color: t.text,
                            fontSize: 22,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 10),
                        ValueListenableBuilder(
                          valueListenable: GestureTurn.instance.seen,
                          builder: (context, seen, _) => Text(
                            '脸 ${seen.$1 ? '✓' : '—'}   手 ${seen.$2 ? '✓' : '—'}',
                            style: TextStyle(color: t.muted, fontSize: 12),
                          ),
                        ),
                      ],
                    ),
            ),
            const SizedBox(height: 16),
            Material(
              clipBehavior: Clip.antiAlias,
              color: t.surface,
              shape: RoundedRectangleBorder(
                side: BorderSide(color: t.outline),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                children: [
                  SwitchListTile(
                    title: Text(
                      '在阅读时开启',
                      style: TextStyle(color: t.text, fontSize: 14),
                    ),
                    value: s.gestureTurn,
                    onChanged: s.setGestureTurn,
                  ),
                  for (final name in GestureTurn.names.keys) ...[
                    Divider(height: 1, color: t.outline),
                    _gesture(t, s, name),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// One gesture: on or off, and when on, which way it turns.
  Widget _gesture(ReadingTheme t, ReadingSettings s, String name) {
    final way = s.gestureActions[name];
    Widget choice(String label, int value) => ChoiceChip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      selected: way == value,
      onSelected: (_) => s.setGestureAction(name, value),
    );
    return ListTile(
      title: Text(
        GestureTurn.names[name]!,
        style: TextStyle(color: t.text, fontSize: 14),
      ),
      subtitle: way == null
          ? null
          : Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(
                spacing: 8,
                children: [choice('下一页', 1), choice('上一页', -1)],
              ),
            ),
      trailing: Switch(
        value: way != null,
        onChanged: (on) => s.setGestureAction(name, on ? 1 : 0),
      ),
    );
  }
}
