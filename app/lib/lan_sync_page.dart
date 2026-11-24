import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart' hide Text;
import 'package:path_provider/path_provider.dart';

import 'app_localizations.dart';
import 'bloom.dart';
import 'lan_sync.dart';
import 'src/rust/api/sync.dart';
import 'theme.dart';

/// Local-network zero-cloud synchronization page (Windows / Android / iOS).
///
/// Works entirely over the same Wi-Fi without any cloud server or account:
/// - Automatically starts a local host & discovers nearby Zhiyue devices;
/// - Previews exact diffs & Git-style progress conflicts before writing;
/// - Never drops books (same-title different editions are kept side-by-side);
/// - Takes an automatic pre-sync SQLite snapshot with one-tap rollback.
class LanSyncPage extends StatefulWidget {
  final ReadingSettings settings;

  const LanSyncPage({super.key, required this.settings});

  @override
  State<LanSyncPage> createState() => _LanSyncPageState();
}

class _LanSyncPageState extends State<LanSyncPage> {
  late final LanSyncHost _host;
  LanSyncDiscovery? _discovery;
  List<String> _localIps = const [];
  List<LanSyncPeer> _peers = const [];
  String? _hostActivity;
  bool _hasRollback = false;

  // Manual connect fields (fallback when UDP broadcast is blocked on a router).
  final _hostCtrl = TextEditingController();
  final _portCtrl = TextEditingController();
  final _pinCtrl = TextEditingController();
  bool _showManual = false;

  // Active merge preview / execution state.
  bool _connecting = false;
  LanSyncSession? _session;
  final Map<String, String> _resolutions = {};
  bool _syncBookFiles = true;
  bool _merging = false;
  bool _exporting = false;
  bool _exportIncludeBooks = true;
  String _mergeStatus = '';
  double _mergeProgress = 0;
  LanSyncOutcome? _outcome;

  @override
  void initState() {
    super.initState();
    _host = LanSyncHost(
      onRemoteActivity: (msg) {
        if (mounted) {
          setState(() => _hostActivity = msg);
          _refreshRollback();
        }
      },
    );
    _boot();
  }

  Future<void> _boot() async {
    await _host.start();
    final ips = await localLanIpv4Addresses();
    final rollback = await syncHasRollback().catchError((_) => false);
    _discovery = LanSyncDiscovery(
      onChanged: (peers) {
        if (mounted) setState(() => _peers = peers);
      },
    );
    await _discovery!.start();
    if (mounted) {
      setState(() {
        _localIps = ips;
        _hasRollback = rollback;
      });
    }
  }

  Future<void> _refreshRollback() async {
    final rollback = await syncHasRollback().catchError((_) => false);
    if (mounted) setState(() => _hasRollback = rollback);
  }

  @override
  void dispose() {
    _discovery?.stop();
    _host.stop();
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _pinCtrl.dispose();
    super.dispose();
  }

  Future<void> _promptPinAndConnect(LanSyncPeer peer) async {
    final t = widget.settings.theme;
    final ctrl = TextEditingController();
    final pin = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: t.raisedSurface,
        title: Text(
          '连接到 ${peer.name}',
          style: TextStyle(color: t.text, fontSize: 16),
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          maxLength: 4,
          style: TextStyle(color: t.text, fontSize: 18, letterSpacing: 6),
          decoration: InputDecoration(
            labelText: '输入对端显示的 4 位配对码',
            labelStyle: TextStyle(color: t.muted, fontSize: 13),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('取消', style: TextStyle(color: t.muted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('连接'),
          ),
        ],
      ),
    );
    if (pin == null || pin.isEmpty || !mounted) return;
    await _connect(peer.host, peer.port, pin);
  }

  Future<void> _connect(String host, int port, String pin) async {
    setState(() {
      _connecting = true;
      _outcome = null;
    });
    try {
      final session = await LanSyncClient.connectAndPlan(
        host: host,
        port: port,
        pin: pin,
      );
      final defaults = <String, String>{};
      for (final c in session.plan.progressConflicts) {
        defaults[c.syncUid] = 'further_bookmark';
      }
      if (mounted) {
        setState(() {
          _session = session;
          _resolutions
            ..clear()
            ..addAll(defaults);
          _connecting = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _connecting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('连接失败：$e')),
        );
      }
    }
  }

  Future<void> _runMerge() async {
    final session = _session;
    if (session == null || _merging) return;
    setState(() {
      _merging = true;
      _mergeStatus = '正在准备同步…';
      _mergeProgress = 0.05;
    });
    try {
      final outcome = session.isFileImport
          ? await LocalBackupArchive.applyFileImport(
              session: session,
              resolutions: Map<String, String>.from(_resolutions),
              importBookFiles: _syncBookFiles,
              onProgress: (status, progress) {
                if (mounted) {
                  setState(() {
                    _mergeStatus = status;
                    _mergeProgress = progress;
                  });
                }
              },
            )
          : await LanSyncClient.executeBidirectionalMerge(
              session: session,
              resolutions: Map<String, String>.from(_resolutions),
              syncBookFiles: _syncBookFiles,
              onProgress: (status, progress) {
                if (mounted) {
                  setState(() {
                    _mergeStatus = status;
                    _mergeProgress = progress;
                  });
                }
              },
            );
      await _refreshRollback();
      if (mounted) {
        setState(() {
          _merging = false;
          _outcome = outcome;
          _session = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _merging = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('同步中断：$e')),
        );
      }
    }
  }

  Future<void> _exportBackup() async {
    if (_exporting) return;
    final now = DateTime.now();
    final stamp =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_'
        '${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}';
    final defaultName = 'zhiyue_backup_$stamp.zip';
    String? savePath;
    try {
      if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
        savePath = await FilePicker.saveFile(
          dialogTitle: '导出挚阅数据包',
          fileName: defaultName,
          type: FileType.custom,
          allowedExtensions: const ['zip'],
        );
      } else {
        final dir =
            await getExternalStorageDirectory() ??
            await getApplicationDocumentsDirectory();
        savePath = '${dir.path}${Platform.pathSeparator}$defaultName';
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('选择导出路径失败：$e')),
        );
      }
      return;
    }
    if (savePath == null || savePath.trim().isEmpty || !mounted) return;
    if (!savePath.toLowerCase().endsWith('.zip')) savePath = '$savePath.zip';

    setState(() {
      _exporting = true;
      _mergeStatus = '正在导出备份包…';
      _mergeProgress = 0.05;
    });
    try {
      final res = await LocalBackupArchive.exportToZip(
        outputPath: savePath,
        includeBookFiles: _exportIncludeBooks,
        onProgress: (s, p) {
          if (mounted) {
            setState(() {
              _mergeStatus = s;
              _mergeProgress = p;
            });
          }
        },
      );
      if (mounted) {
        setState(() => _exporting = false);
        final mb = (res.totalBytes / (1024 * 1024)).toStringAsFixed(2);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '已导出备份包（$mb MB，含 ${res.bookFilesBundled} 本书文件）：$savePath',
            ),
            duration: const Duration(seconds: 5),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _exporting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出失败：$e')),
        );
      }
    }
  }

  Future<void> _importBackup() async {
    final picked = await FilePicker.pickFiles(
      dialogTitle: '选择挚阅备份文件（.zip / .json）',
      type: FileType.custom,
      allowedExtensions: const ['zip', 'json'],
    );
    final path = picked?.files.single.path;
    if (path == null || path.isEmpty || !mounted) return;
    setState(() {
      _connecting = true;
      _outcome = null;
    });
    try {
      final session = await LocalBackupArchive.inspectFile(path);
      final defaults = <String, String>{};
      for (final c in session.plan.progressConflicts) {
        defaults[c.syncUid] = 'further_bookmark';
      }
      if (mounted) {
        setState(() {
          _session = session;
          _resolutions
            ..clear()
            ..addAll(defaults);
          _connecting = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _connecting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('读取备份文件失败：$e')),
        );
      }
    }
  }

  Future<void> _rollback() async {
    final t = widget.settings.theme;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: t.raisedSurface,
        title: Text('回滚上次同步？', style: TextStyle(color: t.text, fontSize: 16)),
        content: Text(
          '将把本机数据库恢复到上次局域网同步前的自动快照。已传输的书籍文件不会丢失。',
          style: TextStyle(color: t.muted, fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消', style: TextStyle(color: t.muted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认回滚', style: TextStyle(color: Color(0xFFB3574D))),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final restored = await syncRollbackLast();
      await _refreshRollback();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(restored ? '已恢复到上次同步前的状态' : '没有可用的快照')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('回滚失败：$e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.settings.theme;
    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        backgroundColor: t.topBar,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: t.muted),
        title: Text('数据同步与备份', style: TextStyle(color: t.text, fontSize: 16)),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 44),
            children: [
              if (_session != null)
                _mergePlanView(_session!, t)
              else ...[
                _backupFileCard(t),
                const SizedBox(height: 16),
                _thisDeviceCard(t),
                const SizedBox(height: 18),
                if (_outcome != null) ...[
                  _outcomeCard(_outcome!, t),
                  const SizedBox(height: 18),
                ],
                _nearbySection(t),
                const SizedBox(height: 16),
                _manualConnectCard(t),
                if (_hasRollback) ...[
                  const SizedBox(height: 20),
                  OutlinedButton.icon(
                    onPressed: _rollback,
                    icon: const Icon(Icons.restore, size: 18),
                    label: const Text('撤销上次同步（恢复自动快照）'),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _backupFileCard(ReadingTheme t) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: t.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.archive_outlined, color: t.text, size: 20),
              const SizedBox(width: 8),
              Text(
                '离线数据包导出 / 导入',
                style: TextStyle(
                  color: t.text,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '把全部阅读数据、书名、进度、书签、批注、文本清理规则、彩蛋与书籍原文件打包保存；可在任意其他设备导入并安全合并，绝不丢书。',
            style: TextStyle(color: t.muted, fontSize: 12.5, height: 1.5),
          ),
          const SizedBox(height: 6),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              '导出时同时打包书籍原文件（TXT 与封面）',
              style: TextStyle(color: t.text, fontSize: 13),
            ),
            value: _exportIncludeBooks,
            onChanged: _exporting
                ? null
                : (v) => setState(() => _exportIncludeBooks = v),
          ),
          if (_exporting) ...[
            LinearProgressIndicator(value: _mergeProgress),
            const SizedBox(height: 6),
            Text(_mergeStatus, style: TextStyle(color: t.muted, fontSize: 12)),
            const SizedBox(height: 8),
          ],
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _exporting || _connecting ? null : _exportBackup,
                  icon: const Icon(Icons.upload_file_outlined, size: 18),
                  label: const Text('导出数据包'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _exporting || _connecting ? null : _importBackup,
                  icon: const Icon(Icons.download_outlined, size: 18),
                  label: const Text('导入并合并'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _thisDeviceCard(ReadingTheme t) {
    final ipText = _localIps.isEmpty
        ? '未检测到局域网 Wi-Fi'
        : '${_localIps.first}:${_host.port}';
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: t.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.wifi_tethering, color: t.text, size: 20),
              const SizedBox(width: 8),
              Text(
                '本机已就绪（零云端直连）',
                style: TextStyle(
                  color: t.text,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '另一台设备打开同一 Wi-Fi 下的「局域网三端同步」即可自动发现本机；合并过程只增不丢，同名不同版本书籍会分别保留。',
            style: TextStyle(color: t.muted, fontSize: 12.5, height: 1.5),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('本机地址', style: TextStyle(color: t.muted, fontSize: 11.5)),
                    const SizedBox(height: 2),
                    Text(
                      ipText,
                      translate: false,
                      style: TextStyle(color: t.text, fontSize: 14),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: t.text.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  children: [
                    Text('配对码', style: TextStyle(color: t.muted, fontSize: 10.5)),
                    Text(
                      _host.pin,
                      translate: false,
                      style: TextStyle(
                        color: t.text,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (_hostActivity != null) ...[
            const SizedBox(height: 10),
            Text(
              _hostActivity!,
              style: TextStyle(color: t.text, fontSize: 12.5),
            ),
          ],
        ],
      ),
    );
  }

  Widget _nearbySection(ReadingTheme t) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: t.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '附近设备',
                style: TextStyle(
                  color: t.text,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              if (_connecting)
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: t.muted,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (_peers.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Row(
                children: [
                  Bloom(color: t.muted, size: 22),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '正在同一 Wi-Fi 下搜索其他挚阅设备…',
                      style: TextStyle(color: t.muted, fontSize: 13),
                    ),
                  ),
                ],
              ),
            )
          else
            for (final p in _peers)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  p.platform == 'Windows'
                      ? Icons.computer
                      : Icons.smartphone,
                  color: t.text,
                ),
                title: Text(
                  p.name,
                  translate: false,
                  style: TextStyle(color: t.text, fontSize: 14),
                ),
                subtitle: Text(
                  '${p.host}:${p.port}',
                  translate: false,
                  style: TextStyle(color: t.muted, fontSize: 12),
                ),
                trailing: FilledButton.tonal(
                  onPressed: _connecting ? null : () => _promptPinAndConnect(p),
                  child: const Text('连接'),
                ),
              ),
        ],
      ),
    );
  }

  Widget _manualConnectCard(ReadingTheme t) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: t.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _showManual = !_showManual),
            child: Row(
              children: [
                Icon(Icons.link, size: 18, color: t.muted),
                const SizedBox(width: 8),
                Text(
                  '手动输入地址连接（若路由器限制自动发现）',
                  style: TextStyle(color: t.text, fontSize: 13.5),
                ),
                const Spacer(),
                Icon(
                  _showManual ? Icons.expand_less : Icons.expand_more,
                  color: t.muted,
                ),
              ],
            ),
          ),
          if (_showManual) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _hostCtrl,
                    style: TextStyle(color: t.text, fontSize: 13.5),
                    decoration: InputDecoration(
                      labelText: 'IP 地址（如 192.168.1.8）',
                      labelStyle: TextStyle(color: t.muted, fontSize: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _portCtrl,
                    keyboardType: TextInputType.number,
                    style: TextStyle(color: t.text, fontSize: 13.5),
                    decoration: InputDecoration(
                      labelText: '端口',
                      labelStyle: TextStyle(color: t.muted, fontSize: 12),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _pinCtrl,
                    keyboardType: TextInputType.number,
                    maxLength: 4,
                    style: TextStyle(color: t.text, fontSize: 13.5),
                    decoration: InputDecoration(
                      labelText: '4 位配对码',
                      labelStyle: TextStyle(color: t.muted, fontSize: 12),
                      counterText: '',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: _connecting
                      ? null
                      : () {
                          final h = _hostCtrl.text.trim();
                          final p = int.tryParse(_portCtrl.text.trim()) ?? 0;
                          final pin = _pinCtrl.text.trim();
                          if (h.isEmpty || p <= 0 || pin.isEmpty) return;
                          _connect(h, p, pin);
                        },
                  child: const Text('预览差异'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _mergePlanView(LanSyncSession session, ReadingTheme t) {
    final plan = session.plan;
    final hasSameTitleDiff =
        plan.booksToPull.any((b) => b.sameTitleDifferentEdition) ||
        plan.booksToPush.any((b) => b.sameTitleDifferentEdition);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: t.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: t.outline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '合并预览 · ${plan.remoteDeviceName}',
                translate: false,
                style: TextStyle(
                  color: t.text,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              _summaryRow(t, '已匹配同一本书', '${plan.matchedBooks} 本'),
              _summaryRow(t, '将从对端接收新书', '${plan.booksToPull.length} 本'),
              _summaryRow(t, '将向对端发送新书', '${plan.booksToPush.length} 本'),
              _summaryRow(t, '自动快进进度', '${plan.autoProgressUpdates} 本'),
              _summaryRow(
                t,
                '将自动合并记录',
                '${plan.eventsToAdd} 条时长 · ${plan.bookmarksToAdd} 书签 · ${plan.annotationsToAdd} 标注',
              ),
              if (plan.archivesToAdd.toInt() > 0)
                _summaryRow(
                  t,
                  '将合并历史已删书统计',
                  '${plan.archivesToAdd} 本',
                ),
              if (hasSameTitleDiff) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: t.text.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '检测到同名但内容哈希不同的书籍版本：系统不会强行覆盖或合并，两本都会完整保留。',
                    style: TextStyle(color: t.text, fontSize: 12, height: 1.45),
                  ),
                ),
              ],
              const SizedBox(height: 10),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  '同步缺失的书籍原文件（TXT 与封面）',
                  style: TextStyle(color: t.text, fontSize: 13.5),
                ),
                value: _syncBookFiles,
                onChanged: _merging
                    ? null
                    : (v) => setState(() => _syncBookFiles = v),
              ),
            ],
          ),
        ),
        if (plan.progressConflicts.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(
            '阅读进度分叉（共 ${plan.progressConflicts.length} 本需选择合并方式）',
            style: TextStyle(
              color: t.text,
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          for (final c in plan.progressConflicts) _conflictCard(c, t),
        ],
        const SizedBox(height: 18),
        if (_merging) ...[
          LinearProgressIndicator(value: _mergeProgress),
          const SizedBox(height: 8),
          Text(_mergeStatus, style: TextStyle(color: t.muted, fontSize: 12.5)),
        ] else
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => setState(() => _session = null),
                  child: const Text('取消'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: FilledButton(
                  onPressed: _runMerge,
                  child: Text(
                    session.isFileImport ? '确认并导入合并' : '确认并双向合并',
                  ),
                ),
              ),
            ],
          ),
      ],
    );
  }

  Widget _conflictCard(SyncProgressConflict c, ReadingTheme t) {
    final selected = _resolutions[c.syncUid] ?? 'further_bookmark';
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: t.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '《${c.title}》',
            translate: false,
            style: TextStyle(
              color: t.text,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '本机：第 ${c.localChapter + 1} 章   ·   对端：第 ${c.remoteChapter + 1} 章',
            style: TextStyle(color: t.muted, fontSize: 12.5),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              ChoiceChip(
                label: const Text('取更靠前，另一端存书签（推荐）'),
                selected: selected == 'further_bookmark',
                onSelected: _merging
                    ? null
                    : (_) => setState(
                        () => _resolutions[c.syncUid] = 'further_bookmark',
                      ),
              ),
              ChoiceChip(
                label: Text('保留本机（第 ${c.localChapter + 1} 章）'),
                selected: selected == 'local',
                onSelected: _merging
                    ? null
                    : (_) => setState(() => _resolutions[c.syncUid] = 'local'),
              ),
              ChoiceChip(
                label: Text('采用对端（第 ${c.remoteChapter + 1} 章）'),
                selected: selected == 'remote',
                onSelected: _merging
                    ? null
                    : (_) => setState(() => _resolutions[c.syncUid] = 'remote'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _outcomeCard(LanSyncOutcome o, ReadingTheme t) {
    final r = o.localResult;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: t.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.check_circle_outline, color: t.text, size: 18),
              const SizedBox(width: 8),
              Text(
                o.remoteApplied ? '双端同步合并已完成' : '本机合并已完成',
                style: TextStyle(
                  color: t.text,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '本机新增 ${r.booksImported} 本书 · 更新 ${r.progressUpdated} 本进度 · '
            '合并 ${r.eventsAdded} 条阅读时长 · ${r.bookmarksAdded} 个书签 · '
            '${r.annotationsAdded} 条标注 · ${o.localEggsAdded} 个彩蛋',
            style: TextStyle(color: t.muted, fontSize: 12.5, height: 1.5),
          ),
          if (o.remoteNote != null) ...[
            const SizedBox(height: 6),
            Text(
              o.remoteNote!,
              style: const TextStyle(color: Color(0xFFB3574D), fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }

  Widget _summaryRow(ReadingTheme t, String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        Text(label, style: TextStyle(color: t.muted, fontSize: 13)),
        const Spacer(),
        Text(value, style: TextStyle(color: t.text, fontSize: 13)),
      ],
    ),
  );
}
