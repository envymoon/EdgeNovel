// frb 的 Int64List（Web 上可退化为 BigInt 列表），非 dart:typed_data 的同名类型。
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart' show Int64List;
import 'package:flutter/material.dart';

import 'ai_page.dart';
import 'ai_runtime_page.dart';
import 'bloom.dart';
import 'book_detail_page.dart';
import 'cover.dart';
import 'discover_page.dart';
import 'desktop_book_drop.dart';
import 'platform_support.dart';
import 'platform_services.dart';
import 'reader_state.dart';
import 'settings_page.dart';
import 'shelf_categories.dart';
import 'stats_page.dart';
import 'src/rust/api/book.dart';
import 'theme.dart';

class ShelfPage extends StatefulWidget {
  final ReaderState reader;
  final ReadingSettings settings;
  final VoidCallback onOpened;

  const ShelfPage({
    super.key,
    required this.reader,
    required this.settings,
    required this.onOpened,
  });

  @override
  State<ShelfPage> createState() => _ShelfPageState();
}

class _ShelfPageState extends State<ShelfPage> {
  bool _dragging = false;
  bool _searching = false;
  String _query = '';
  String? _selectedCategory;

  ShelfCategories get _categories => ShelfCategories.instance;

  @override
  void initState() {
    super.initState();
    widget.reader.loadLibrary();
  }

  Future<void> _addBooks(Iterable<String> paths) async {
    final n = await widget.reader.importPaths(paths);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(n > 0 ? '已导入 $n 本' : '没有可导入的 TXT 文件')),
    );
  }

  Future<void> _import() async {
    final paths = await AppServices.instance.files.pickBooks();
    if (paths.isEmpty) return;
    await _addBooks(paths);
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.settings.theme;
    final compact =
        AppPlatformSupport.layoutForWidth(MediaQuery.sizeOf(context).width) ==
        AppLayoutClass.compact;
    return ListenableBuilder(
      listenable: Listenable.merge([widget.reader, _categories]),
      builder: (context, _) {
        if (_selectedCategory != null &&
            !_categories.names.contains(_selectedCategory)) {
          _selectedCategory = null;
        }
        final q = _query.trim();
        final books = widget.reader.shelf.where((book) {
          final inCategory =
              _selectedCategory == null ||
              _categories.categoryFor(book.id) == _selectedCategory;
          final matches =
              q.isEmpty ||
              book.title.contains(q) ||
              (book.author?.contains(q) ?? false);
          return inCategory && matches;
        }).toList();
        return Scaffold(
          appBar: AppBar(
            backgroundColor: t.background,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            title: _searching
                ? TextField(
                    autofocus: true,
                    style: TextStyle(color: t.text, fontSize: 15),
                    cursorColor: t.text,
                    decoration: InputDecoration(
                      hintText: '书名或作者',
                      hintStyle: TextStyle(color: t.muted, fontSize: 15),
                      border: InputBorder.none,
                    ),
                    onChanged: (v) => setState(() => _query = v),
                  )
                : Text('书架', style: TextStyle(color: t.text, fontSize: 17)),
            actions: [
              IconButton(
                tooltip: _searching ? '关闭搜索' : '搜索',
                icon: Icon(_searching ? Icons.close : Icons.search),
                color: t.muted,
                onPressed: () => setState(() {
                  _searching = !_searching;
                  _query = '';
                }),
              ),
              if (!compact)
                IconButton(
                  tooltip: '找书',
                  icon: const Icon(Icons.travel_explore),
                  color: t.muted,
                  onPressed: _openDiscover,
                ),
              IconButton(
                tooltip: '导入 TXT',
                icon: const Icon(Icons.add),
                color: t.muted,
                onPressed: _import,
              ),
              PopupMenuButton<String>(
                tooltip: '更多',
                icon: Icon(Icons.more_vert, color: t.muted),
                onSelected: _handleShelfMenu,
                itemBuilder: (_) => [
                  if (compact)
                    const PopupMenuItem(
                      value: 'discover',
                      child: ListTile(
                        leading: Icon(Icons.travel_explore),
                        title: Text('找书'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  PopupMenuItem(
                    value: 'ai',
                    child: ListTile(
                      leading: Icon(Icons.auto_awesome_outlined),
                      title: Text('本地 AI'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  PopupMenuItem(
                    value: 'stats',
                    child: ListTile(
                      leading: Icon(Icons.insights_outlined),
                      title: Text('阅读数据'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  PopupMenuItem(
                    value: 'theme',
                    child: ListTile(
                      leading: Icon(Icons.palette_outlined),
                      title: Text('主题色'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  PopupMenuItem(
                    value: 'settings',
                    child: ListTile(
                      leading: Icon(Icons.tune),
                      title: Text('设置'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ],
              ),
            ],
          ),
          body: SafeArea(
            top: false,
            child: DesktopBookDrop(
              onDraggingChanged: (value) => setState(() => _dragging = value),
              onPathsDropped: _addBooks,
              child: Container(
                // A visible answer to "can I drop this here?" the moment the file
                // enters the window, not after it lands.
                decoration: BoxDecoration(
                  border: Border.all(
                    color: _dragging
                        ? t.text.withValues(alpha: 0.5)
                        : Colors.transparent,
                    width: 2,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  children: [
                    if (widget.reader.enriching ||
                        widget.reader.enrichError != null)
                      _enrichBanner(t),
                    if (widget.reader.indexing ||
                        widget.reader.indexError != null)
                      _indexBanner(t),
                    if (widget.reader.aiQueuedCount > 0 &&
                        !widget.reader.enriching &&
                        !widget.reader.indexing &&
                        widget.reader.enrichError == null &&
                        widget.reader.indexError == null)
                      _queueBanner(t),
                    _categoryBar(t),
                    Expanded(
                      child: widget.reader.loading
                          ? Center(child: Bloom(color: t.muted, size: 34))
                          : books.isEmpty
                          ? _empty(t)
                          : q.isNotEmpty
                          ? ListView.separated(
                              padding: const EdgeInsets.all(16),
                              itemCount: books.length,
                              separatorBuilder: (_, _) =>
                                  const SizedBox(height: 12),
                              itemBuilder: (context, i) => _card(books[i]),
                            )
                          // Press-and-hold, then drag. The top pinned zone
                          // is hand-ordered; dropping a book there pins it
                          // at that slot, dragging one out unpins it. The
                          // rest of the shelf orders itself by recency.
                          : ReorderableListView.builder(
                              padding: const EdgeInsets.all(16),
                              buildDefaultDragHandles: false,
                              itemCount: books.length,
                              onReorderItem: (a, b) => _reorder(books, a, b),
                              itemBuilder: (context, i) => Padding(
                                key: ValueKey(books[i].id),
                                padding: const EdgeInsets.only(bottom: 12),
                                child: ReorderableDelayedDragStartListener(
                                  index: i,
                                  child: _card(books[i]),
                                ),
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _handleShelfMenu(String value) {
    switch (value) {
      case 'discover':
        _openDiscover();
        return;
      case 'ai':
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => AiPage(settings: widget.settings)),
        );
        return;
      case 'stats':
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => StatsPage(settings: widget.settings),
          ),
        );
        return;
      case 'theme':
        _pickTheme();
        return;
      case 'settings':
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => SettingsPage(settings: widget.settings),
          ),
        );
        return;
    }
  }

  void _openDiscover() => Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) =>
          DiscoverPage(reader: widget.reader, settings: widget.settings),
    ),
  );

  Widget _categoryBar(ReadingTheme t) => SizedBox(
    height: 50,
    child: ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 8, 12, 4),
      children: [
        ChoiceChip(
          label: const Text('全部'),
          selected: _selectedCategory == null,
          onSelected: (_) => setState(() => _selectedCategory = null),
        ),
        for (final name in _categories.names) ...[
          const SizedBox(width: 8),
          ChoiceChip(
            label: Text(name),
            selected: _selectedCategory == name,
            onSelected: (_) => setState(() => _selectedCategory = name),
          ),
        ],
        const SizedBox(width: 8),
        IconButton(
          tooltip: '管理分类',
          visualDensity: VisualDensity.compact,
          onPressed: _manageCategories,
          icon: Icon(Icons.add_circle_outline, color: t.muted, size: 21),
        ),
      ],
    ),
  );

  Future<String?> _askCategoryName({String initial = ''}) async {
    final controller = TextEditingController(text: initial);
    final t = widget.settings.theme;
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: t.background,
        title: Text(
          initial.isEmpty ? '新建分类' : '重命名分类',
          style: TextStyle(color: t.text, fontSize: 16),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 16,
          decoration: const InputDecoration(hintText: '例如：正在读、古风、轻松'),
          onSubmitted: (value) => Navigator.pop(dialogContext, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text('取消', style: TextStyle(color: t.muted)),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    return value?.trim();
  }

  Future<String?> _createCategory() async {
    final name = await _askCategoryName();
    if (name == null || name.isEmpty) return null;
    if (!_categories.add(name) && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('分类名称已存在')));
      return null;
    }
    return name;
  }

  Future<void> _deleteCategory(String name) async {
    final t = widget.settings.theme;
    final assigned = widget.reader.shelf
        .where((book) => _categories.categoryFor(book.id) == name)
        .length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: t.background,
        title: Text(
          '删除分类“$name”？',
          style: TextStyle(color: t.text, fontSize: 16),
        ),
        content: Text(
          assigned == 0 ? '只删除这个分类。' : '这个分类中有 $assigned 本书。删除分类不会删除书籍。',
          style: TextStyle(color: t.muted, fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text('取消', style: TextStyle(color: t.muted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text(
              '删除分类',
              style: TextStyle(color: Color(0xFFB3574D)),
            ),
          ),
        ],
      ),
    );
    if (ok == true) _categories.delete(name);
  }

  void _manageCategories() {
    final t = widget.settings.theme;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: t.background,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: ListenableBuilder(
          listenable: _categories,
          builder: (context, _) => Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  title: Text(
                    '书架分类',
                    style: TextStyle(
                      color: t.text,
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    '只创建你需要的分类',
                    style: TextStyle(color: t.muted, fontSize: 11.5),
                  ),
                  trailing: IconButton(
                    tooltip: '新建分类',
                    onPressed: _createCategory,
                    icon: const Icon(Icons.add),
                  ),
                ),
                if (_categories.names.isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 18, 24, 26),
                    child: Text(
                      '还没有自定义分类',
                      style: TextStyle(color: t.muted, fontSize: 13),
                    ),
                  )
                else
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final name in _categories.names)
                          ListTile(
                            leading: Icon(
                              Icons.folder_outlined,
                              color: t.muted,
                            ),
                            title: Text(name, style: TextStyle(color: t.text)),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: '重命名',
                                  icon: const Icon(
                                    Icons.edit_outlined,
                                    size: 20,
                                  ),
                                  color: t.muted,
                                  onPressed: () async {
                                    final next = await _askCategoryName(
                                      initial: name,
                                    );
                                    if (next != null && next.isNotEmpty) {
                                      _categories.rename(name, next);
                                    }
                                  },
                                ),
                                IconButton(
                                  tooltip: '删除分类',
                                  icon: const Icon(
                                    Icons.delete_outline,
                                    size: 20,
                                  ),
                                  color: const Color(0xFFB3574D),
                                  onPressed: () => _deleteCategory(name),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The index run's face, next to the summary run's. They are two halves of the
  /// same idea — a one-off AI pass over the whole book that nothing else can use
  /// until it finishes — so they are started from the same menu and reported in
  /// the same place, rather than the index being something you could only stumble
  /// into from inside search.
  Widget _indexBanner(ReadingTheme t) {
    final r = widget.reader;
    final p = r.indexProgress;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: r.indexError != null
          ? Text(
              '索引失败：${r.indexError}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xFFB3574D), fontSize: 12),
            )
          : BloomProgress(
              label: p == null
                  ? '正在启动本机引擎…'
                  : '《${r.indexingTitle ?? ''}》索引中 · ${p.done} / ${p.total}',
              detail: p?.title,
              value: p == null || p.total == 0 ? null : p.done / p.total,
              color: t.muted,
              textColor: t.text,
              trailing: TextButton(
                onPressed: r.stopIndex,
                child: const Text('停止', style: TextStyle(fontSize: 12)),
              ),
            ),
    );
  }

  Widget _queueBanner(ReadingTheme t) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
    child: Material(
      color: t.text.withValues(alpha: 0.035),
      borderRadius: BorderRadius.circular(10),
      child: ListTile(
        dense: true,
        leading: Icon(Icons.schedule_outlined, color: t.muted, size: 20),
        title: Text(
          widget.reader.aiQueueState,
          style: TextStyle(color: t.text, fontSize: 12.5),
        ),
        subtitle: widget.reader.aiQueueDetail == null
            ? null
            : Text(
                widget.reader.aiQueueDetail!,
                style: TextStyle(color: t.muted, fontSize: 10.5),
              ),
        trailing: Icon(Icons.chevron_right, color: t.muted, size: 18),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) =>
                AiRuntimePage(settings: widget.settings, reader: widget.reader),
          ),
        ),
      ),
    ),
  );

  /// The enrichment run lives in [ReaderState]; this banner is just its face.
  /// Cancelling loses nothing — every finished chapter is already on disk.
  Widget _enrichBanner(ReadingTheme t) {
    final r = widget.reader;
    final p = r.enrichProgress;
    final failed = r.enrichError != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: failed
          ? Text(
              '摘要生成失败：${r.enrichError}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xFFB3574D), fontSize: 12),
            )
          : BloomProgress(
              label: p == null
                  ? '正在启动本机引擎…'
                  : '《${r.enrichingTitle}》摘要生成中 · ${p.done} / ${p.total}',
              // Until the first chapter comes back there is nothing to divide,
              // so the bar sweeps and the flower carries the "alive" signal.
              detail: p?.title,
              value: p == null || p.total == 0 ? null : p.done / p.total,
              color: t.muted,
              textColor: t.text,
              trailing: r.enriching
                  ? TextButton(
                      onPressed: r.stopEnrich,
                      child: const Text('停止', style: TextStyle(fontSize: 12)),
                    )
                  : null,
            ),
    );
  }

  /// The same swatches the reader has, on the shelf. It writes to the shared
  /// [ReadingSettings], so the shelf recolours under the sheet and the choice is
  /// already in force the next time a book is opened.
  void _pickTheme() {
    final t = widget.settings.theme;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: t.background,
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [ThemeSwatches(settings: widget.settings)],
        ),
      ),
    );
  }

  Future<void> _editInfo(ShelfItem b) async {
    final t = widget.settings.theme;
    final nameCtl = TextEditingController(text: b.title);
    final authorCtl = TextEditingController(text: b.author ?? '');
    String? coverPath = b.coverPath;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: t.background,
          title: Text('编辑信息', style: TextStyle(color: t.text, fontSize: 16)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextCover(
                      title: nameCtl.text.isEmpty ? b.title : nameCtl.text,
                      hue: b.coverHue,
                      coverPath: coverPath,
                      width: 64,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          TextButton.icon(
                            style: TextButton.styleFrom(
                              padding: EdgeInsets.zero,
                              alignment: Alignment.centerLeft,
                            ),
                            icon: const Icon(Icons.image_outlined, size: 18),
                            label: const Text('选择封面'),
                            onPressed: () async {
                              final p = await AppServices.instance.files
                                  .pickCoverImage();
                              if (p != null) setLocal(() => coverPath = p);
                            },
                          ),
                          if (coverPath != null)
                            TextButton.icon(
                              style: TextButton.styleFrom(
                                padding: EdgeInsets.zero,
                                alignment: Alignment.centerLeft,
                              ),
                              icon: const Icon(Icons.restore, size: 18),
                              label: const Text('用默认封面'),
                              onPressed: () => setLocal(() => coverPath = null),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: nameCtl,
                  maxLength: 40,
                  style: TextStyle(color: t.text),
                  decoration: const InputDecoration(
                    labelText: '书名',
                    hintText: '留空恢复原名',
                  ),
                  onChanged: (_) => setLocal(() {}),
                ),
                TextField(
                  controller: authorCtl,
                  maxLength: 30,
                  style: TextStyle(color: t.text),
                  decoration: const InputDecoration(
                    labelText: '作者',
                    hintText: '留空恢复原作者',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('取消', style: TextStyle(color: t.muted)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (saved != true) return;

    await renameBook(bookId: b.id, title: nameCtl.text);
    await setBookAuthor(bookId: b.id, author: authorCtl.text);
    if (coverPath != b.coverPath) {
      if (coverPath == null) {
        await clearBookCover(bookId: b.id);
      } else {
        await setBookCover(bookId: b.id, src: coverPath!);
      }
    }
    await widget.reader.loadLibrary();
  }

  Future<void> _deleteForever(ShelfItem b) async {
    final t = widget.settings.theme;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: t.background,
        title: Text(
          '删除《${b.title}》？',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: t.text, fontSize: 16),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text('取消', style: TextStyle(color: t.muted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('删除', style: TextStyle(color: Color(0xFFB3574D))),
          ),
        ],
      ),
    );
    if (ok == true) {
      await widget.reader.deleteForever(b.id);
      _categories.removeBook(b.id);
    }
  }

  Widget _card(ShelfItem b) => BookCard(
    item: b,
    theme: widget.settings.theme,
    category: _categories.categoryFor(b.id),
    onTap: () => _openBookDetail(b),
    onReport: () => _openBookDetail(b),
    onDelete: () async {
      await widget.reader.delete(b.id);
      _categories.removeBook(b.id);
    },
    onDeleteForever: () => _deleteForever(b),
    onEncoding: () => _pickEncoding(b),
    onRename: () => _editInfo(b),
    onPin: () => _togglePin(b),
    onCategory: () => _chooseCategory(b),
  );

  void _openBookDetail(ShelfItem book) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => BookDetailPage(
          book: book,
          reader: widget.reader,
          settings: widget.settings,
          onRead: (chapter, offset) async {
            await widget.reader.open(book.path);
            if (chapter != null && widget.reader.isOpen) {
              if (offset == null) {
                await widget.reader.goToChapter(chapter);
              } else {
                await widget.reader.goToOffset(chapter, offset);
              }
            }
            if (!mounted || !widget.reader.isOpen) return;
            Navigator.of(context).popUntil((route) => route.isFirst);
            widget.onOpened();
          },
        ),
      ),
    );
  }

  Future<void> _chooseCategory(ShelfItem book) async {
    final t = widget.settings.theme;
    final current = _categories.categoryFor(book.id);
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: t.background,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(
                  '放入分类',
                  style: TextStyle(
                    color: t.text,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Text(
                  book.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: t.muted, fontSize: 11.5),
                ),
              ),
              ListTile(
                leading: Icon(Icons.clear, color: t.muted),
                title: Text('不分类', style: TextStyle(color: t.text)),
                trailing: current == null ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(sheetContext, ''),
              ),
              for (final name in _categories.names)
                ListTile(
                  leading: Icon(Icons.folder_outlined, color: t.muted),
                  title: Text(name, style: TextStyle(color: t.text)),
                  trailing: current == name ? const Icon(Icons.check) : null,
                  onTap: () => Navigator.pop(sheetContext, name),
                ),
              ListTile(
                leading: Icon(Icons.create_new_folder_outlined, color: t.muted),
                title: Text('新建分类', style: TextStyle(color: t.text)),
                onTap: () => Navigator.pop(sheetContext, '__new__'),
              ),
            ],
          ),
        ),
      ),
    );
    if (choice == null) return;
    if (choice == '__new__') {
      final name = await _createCategory();
      if (name != null) _categories.setForBook(book.id, name);
    } else {
      _categories.setForBook(book.id, choice.isEmpty ? null : choice);
    }
  }

  Future<void> _togglePin(ShelfItem b) async {
    await setBookPinned(bookId: b.id, pinned: !b.pinned);
    await widget.reader.loadLibrary();
  }

  /// Where did the book land relative to the pinned zone? Inside it: pin at
  /// exactly that slot. Out of it (for a pinned book): unpin. Entirely within
  /// the recency zone: nothing to persist — recency owns that order, and
  /// pretending otherwise would silently un-stick on the next read.
  Future<void> _reorder(
    List<ShelfItem> books,
    int oldIndex,
    int newIndex,
  ) async {
    if (newIndex == oldIndex) return;
    final moved = books[oldIndex];
    final zone = [
      for (final b in books)
        if (b.pinned && b.id != moved.id) b.id,
    ];
    if (newIndex <= zone.length) {
      await setPinOrder(
        ids: Int64List.fromList([...zone]..insert(newIndex, moved.id)),
      );
    } else if (moved.pinned) {
      await setBookPinned(bookId: moved.id, pinned: false);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('拖到最顶端可置顶')));
      }
      return;
    }
    await widget.reader.loadLibrary();
  }

  /// The escape hatch for a wrong encoding guess: mojibake in the title or the
  /// text is something only a human can see.
  Future<void> _pickEncoding(ShelfItem b) async {
    final t = widget.settings.theme;
    const options = <(String, String)>[
      ('auto', '自动检测'),
      ('GB18030', '简体中文 · GB18030'),
      ('Big5', '繁体中文 · Big5'),
      ('UTF-8', 'UTF-8'),
      ('UTF-16LE', 'UTF-16 LE'),
    ];
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: t.background,
        title: Text('重新指定编码', style: TextStyle(color: t.text, fontSize: 16)),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              '当前识别为 ${b.encoding}',
              style: TextStyle(color: t.muted, fontSize: 12),
            ),
          ),
          for (final (value, label) in options)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, value),
              child: Text(label, style: TextStyle(color: t.text, fontSize: 14)),
            ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    try {
      final enc = await widget.reader.reEncode(
        b,
        choice == 'auto' ? null : choice,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已按 $enc 重新解析《${b.title}》')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('重新解析失败: $e')));
    }
  }

  Widget _empty(ReadingTheme t) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.menu_book_outlined, size: 56, color: t.muted),
        const SizedBox(height: 16),
        Text('书架是空的', style: TextStyle(color: t.muted, fontSize: 15)),
        const SizedBox(height: 6),
        Text(
          AppPlatformSupport.supportsBookDrop
              ? '把 TXT 文件拖进窗口即可导入'
              : '导入 TXT 小说开始阅读',
          style: TextStyle(color: t.muted, fontSize: 12),
        ),
        const SizedBox(height: 20),
        FilledButton.tonal(onPressed: _import, child: const Text('导入 TXT')),
      ],
    ),
  );
}

class BookCard extends StatelessWidget {
  final ShelfItem item;
  final ReadingTheme theme;
  final String? category;
  final VoidCallback onTap;
  final VoidCallback onReport;
  final VoidCallback onDelete;
  final VoidCallback onDeleteForever;
  final VoidCallback onRename;
  final VoidCallback onEncoding;
  final VoidCallback onPin;
  final VoidCallback onCategory;

  const BookCard({
    super.key,
    required this.item,
    required this.theme,
    required this.category,
    required this.onTap,
    required this.onReport,
    required this.onDelete,
    required this.onDeleteForever,
    required this.onEncoding,
    required this.onRename,
    required this.onPin,
    required this.onCategory,
  });

  @override
  Widget build(BuildContext context) {
    final read = item.chapterCount > 0
        ? (item.lastChapter + 1) / item.chapterCount
        : 0.0;
    final started = item.lastOpenedAt != null;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextCover(
              title: item.title,
              hue: item.coverHue,
              coverPath: item.coverPath,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (item.pinned) ...[
                        Icon(Icons.push_pin, size: 13, color: theme.muted),
                        const SizedBox(width: 4),
                      ],
                      Expanded(
                        child: Text(
                          item.title,
                          style: TextStyle(
                            color: theme.text,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        '${item.author ?? '佚名'} · ${item.chapterCount} 章',
                        style: TextStyle(color: theme.muted, fontSize: 12),
                      ),
                      // Two tags at most, and often none. They come from a word
                      // count over the text — no model, no download, no wait —
                      // so they are already there the moment a book is imported.
                      for (final g in item.genreTags)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: theme.muted.withValues(alpha: 0.35),
                            ),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text(
                            g,
                            style: TextStyle(color: theme.muted, fontSize: 10),
                          ),
                        ),
                      if (category != null)
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 100),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: theme.muted.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: Text(
                              category!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: theme.muted,
                                fontSize: 10,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // This line is where a chapter summary will go once the
                  // enrichment pass exists. Until then it says where you were,
                  // which is already the thing a returning reader wants. The
                  // progress ring is deliberately tiny: progress is a glance,
                  // not a feature.
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (started) ...[
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(
                              value: read,
                              strokeWidth: 2,
                              backgroundColor: theme.muted.withValues(
                                alpha: 0.2,
                              ),
                              valueColor: AlwaysStoppedAnimation(theme.muted),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '${(read * 100).toStringAsFixed(0)}%',
                          style: TextStyle(
                            color: theme.muted,
                            fontSize: 11,
                            height: 1.6,
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Expanded(
                        child: Text(
                          started ? '读到 ${item.lastChapterTitle}' : '尚未开始',
                          style: TextStyle(
                            color: theme.muted,
                            fontSize: 13,
                            height: 1.4,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.more_horiz),
              color: theme.muted,
              // This menu has outgrown the default sheet, which is capped at
              // nine sixteenths of the window and does not scroll: the last
              // items were being clipped clean off — present in the code,
              // unreachable on screen, which is how 删除 "disappeared". It
              // scrolls now, and it may use most of the window if it needs to.
              onPressed: () => showModalBottomSheet(
                context: context,
                backgroundColor: theme.background,
                isScrollControlled: true,
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.85,
                ),
                builder: (ctx) => SafeArea(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ListTile(
                          leading: Icon(
                            item.pinned
                                ? Icons.push_pin_outlined
                                : Icons.push_pin,
                            color: theme.text,
                          ),
                          title: Text(
                            item.pinned ? '取消置顶' : '置顶',
                            style: TextStyle(color: theme.text),
                          ),
                          onTap: () {
                            Navigator.pop(ctx);
                            onPin();
                          },
                        ),
                        ListTile(
                          leading: Icon(
                            Icons.folder_outlined,
                            color: theme.text,
                          ),
                          title: Text(
                            category == null ? '加入分类' : '分类 · $category',
                            style: TextStyle(color: theme.text),
                          ),
                          onTap: () {
                            Navigator.pop(ctx);
                            onCategory();
                          },
                        ),
                        ListTile(
                          leading: Icon(
                            Icons.drive_file_rename_outline,
                            color: theme.text,
                          ),
                          title: Text(
                            '编辑信息',
                            style: TextStyle(color: theme.text),
                          ),
                          onTap: () {
                            Navigator.pop(ctx);
                            onRename();
                          },
                        ),
                        ListTile(
                          leading: Icon(Icons.translate, color: theme.text),
                          title: Text(
                            '重新指定编码',
                            style: TextStyle(color: theme.text),
                          ),
                          onTap: () {
                            Navigator.pop(ctx);
                            onEncoding();
                          },
                        ),
                        ListTile(
                          leading: Icon(
                            Icons.fact_check_outlined,
                            color: theme.text,
                          ),
                          title: Text(
                            '扫书报告',
                            style: TextStyle(color: theme.text),
                          ),
                          onTap: () {
                            Navigator.pop(ctx);
                            onReport();
                          },
                        ),
                        ListTile(
                          leading: Icon(
                            Icons.delete_outline,
                            color: theme.text,
                          ),
                          title: Text(
                            '从书架移除',
                            style: TextStyle(color: theme.text),
                          ),
                          onTap: () {
                            Navigator.pop(ctx);
                            onDelete();
                          },
                        ),
                        ListTile(
                          leading: const Icon(
                            Icons.delete_forever_outlined,
                            color: Color(0xFFB3574D),
                          ),
                          title: const Text(
                            '删除',
                            style: TextStyle(color: Color(0xFFB3574D)),
                          ),
                          onTap: () {
                            Navigator.pop(ctx);
                            onDeleteForever();
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
