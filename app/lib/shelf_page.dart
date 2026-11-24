import 'dart:io';

// frb 的 Int64List（Web 上可退化为 BigInt 列表），非 dart:typed_data 的同名类型。
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart' show Int64List;
import 'package:flutter/material.dart' hide Text;

import 'app_localizations.dart';
import 'bloom.dart';
import 'book_detail_page.dart';
import 'cover.dart';
import 'cover_generator.dart';
import 'discover_page.dart';
import 'desktop_book_drop.dart';
import 'easter_eggs.dart';
import 'night_toggle.dart';
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
  int _tab = 0;
  bool _dragging = false;
  bool _searching = false;
  String _query = '';
  String? _selectedCategory;

  ShelfCategories get _categories => ShelfCategories.instance;

  @override
  void initState() {
    super.initState();
    widget.reader.loadLibrary().then((_) {
      if (!mounted) return;
      EasterEggEngine.instance.onShelfLoaded(
        books: [
          for (final b in widget.reader.shelf)
            (chapters: b.chapterCount, lastChapter: b.lastChapter),
        ],
        enabled: widget.settings.easterEggs,
      );
    });
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
    return ListenableBuilder(
      listenable: Listenable.merge([
        widget.reader,
        _categories,
        widget.settings,
      ]),
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
          appBar: switch (_tab) {
            1 => AppBar(
              backgroundColor: t.topBar,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              title: Text(
                '阅读数据',
                style: TextStyle(color: t.text, fontSize: 17),
              ),
              actions: [NightToggle(settings: widget.settings)],
            ),
            2 => null,
            3 => AppBar(
              backgroundColor: t.topBar,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              title: Text(
                '设置',
                style: TextStyle(color: t.text, fontSize: 17),
              ),
              actions: [NightToggle(settings: widget.settings)],
            ),
            _ => AppBar(
              backgroundColor: t.topBar,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              title: _searching
                  ? TextField(
                      autofocus: true,
                      style: TextStyle(color: t.text, fontSize: 15),
                      cursorColor: t.text,
                      decoration: InputDecoration(
                        hintText: context.tr('书名或作者'),
                        hintStyle: TextStyle(color: t.muted, fontSize: 15),
                        border: InputBorder.none,
                      ),
                      onChanged: (v) => setState(() => _query = v),
                    )
                  : Text(
                      '书架',
                      style: TextStyle(color: t.text, fontSize: 17),
                    ),
              actions: [
                IconButton(
                  tooltip: context.tr(
                    widget.settings.shelfCoverMode ? '详情模式' : '封面模式',
                  ),
                  icon: Icon(
                    widget.settings.shelfCoverMode
                        ? Icons.view_list_outlined
                        : Icons.grid_view_outlined,
                  ),
                  color: t.muted,
                  onPressed: () => widget.settings.setShelfCoverMode(
                    !widget.settings.shelfCoverMode,
                  ),
                ),
                NightToggle(settings: widget.settings),
                IconButton(
                  tooltip: context.tr(_searching ? '关闭搜索' : '搜索'),
                  icon: Icon(_searching ? Icons.close : Icons.search),
                  color: t.muted,
                  onPressed: () => setState(() {
                    _searching = !_searching;
                    _query = '';
                  }),
                ),
                IconButton(
                  tooltip: context.tr('导入 TXT'),
                  icon: const Icon(Icons.add),
                  color: t.muted,
                  onPressed: _import,
                ),
              ],
            ),
          },
          body: switch (_tab) {
            1 => SafeArea(
              top: false,
              child: StatsPage(settings: widget.settings, embedded: true),
            ),
            2 => DiscoverPage(
              reader: widget.reader,
              settings: widget.settings,
              embedded: true,
            ),
            3 => SafeArea(
              top: false,
              child: SettingsPage(settings: widget.settings, embedded: true),
            ),
            _ => SafeArea(
              top: false,
              child: DesktopBookDrop(
                onDraggingChanged: (value) =>
                    setState(() => _dragging = value),
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
                      _categoryBar(t),
                      Expanded(
                        child: widget.reader.loading
                            ? Center(child: Bloom(color: t.muted, size: 34))
                            : books.isEmpty
                            ? _empty(t)
                            : widget.settings.shelfCoverMode
                            ? LayoutBuilder(
                                builder: (context, constraints) {
                                  final columns =
                                      (constraints.maxWidth / 140)
                                          .floor()
                                          .clamp(2, 12);
                                  return GridView.builder(
                                    padding: const EdgeInsets.all(16),
                                    gridDelegate:
                                        SliverGridDelegateWithFixedCrossAxisCount(
                                          crossAxisCount: columns,
                                          mainAxisExtent: 208,
                                          crossAxisSpacing: 12,
                                          mainAxisSpacing: 16,
                                        ),
                                    itemCount: books.length,
                                    itemBuilder: (_, i) =>
                                        _coverCard(books[i]),
                                  );
                                },
                              )
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
                                onReorderItem: (a, b) =>
                                    _reorder(books, a, b),
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
          },
          bottomNavigationBar: Container(
            decoration: BoxDecoration(
              color: t.topBar,
              border: Border(top: BorderSide(color: t.outline)),
            ),
            child: NavigationBar(
              height: 62,
              backgroundColor: Colors.transparent,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              selectedIndex: _tab,
              onDestinationSelected: (index) => setState(() {
                _tab = index;
                if (index != 0 && _searching) {
                  _searching = false;
                  _query = '';
                }
              }),
              destinations: [
                NavigationDestination(
                  icon: const Icon(Icons.auto_stories_outlined),
                  selectedIcon: const Icon(Icons.auto_stories),
                  label: context.tr('书架'),
                ),
                NavigationDestination(
                  icon: const Icon(Icons.insights_outlined),
                  selectedIcon: const Icon(Icons.insights),
                  label: context.tr('阅读数据'),
                ),
                NavigationDestination(
                  icon: const Icon(Icons.travel_explore_outlined),
                  selectedIcon: const Icon(Icons.travel_explore),
                  label: context.tr('找书'),
                ),
                NavigationDestination(
                  icon: const Icon(Icons.settings_outlined),
                  selectedIcon: const Icon(Icons.settings),
                  label: context.tr('设置'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

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
          tooltip: context.tr('管理分类'),
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
        backgroundColor: t.raisedSurface,
        title: Text(
          initial.isEmpty ? '新建分类' : '重命名分类',
          style: TextStyle(color: t.text, fontSize: 16),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 16,
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
        backgroundColor: t.raisedSurface,
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
      backgroundColor: t.raisedSurface,
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
                  trailing: IconButton(
                    tooltip: context.tr('新建分类'),
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
                                  tooltip: context.tr('重命名'),
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
                                  tooltip: context.tr('删除分类'),
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

  Future<void> _editInfo(ShelfItem b) async {
    final t = widget.settings.theme;
    final nameCtl = TextEditingController(text: b.title);
    final authorCtl = TextEditingController(text: b.author ?? '');
    String? coverPath = b.coverPath;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: t.raisedSurface,
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
                  decoration: InputDecoration(
                    labelText: context.tr('书名'),
                    hintText: context.tr('留空恢复原名'),
                  ),
                  onChanged: (_) => setLocal(() {}),
                ),
                TextField(
                  controller: authorCtl,
                  maxLength: 30,
                  style: TextStyle(color: t.text),
                  decoration: InputDecoration(
                    labelText: context.tr('作者'),
                    hintText: context.tr('留空恢复原作者'),
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
      // A new cover of the same format is written over the old one's path, and
      // the image cache knows pictures by path: it would keep showing the old.
      if (b.coverPath != null) forgetCovers();
    }
    await widget.reader.loadLibrary();
  }

  /// Draws a cover from the title and genre tags and puts it on the book.
  Future<void> _drawCover(ShelfItem b) async {
    if (!await coverGeneratorReady()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppPlatformSupport.hasBundledImageEngine
                ? '先在 设置 → AI 管理 里装好生图模型'
                : '先在 设置 → AI 管理 里装好生图引擎和模型',
          ),
        ),
      );
      return;
    }
    if (!mounted) return;
    final p = await showCoverGenerator(
      context,
      theme: widget.settings.theme,
      genreTags: b.genreTags,
      title: b.title,
    );
    if (p == null) return;
    await setBookCover(bookId: b.id, src: p);
    // The image cache knows pictures by path, and a new cover of the same
    // format is written over the old one's.
    if (b.coverPath != null) forgetCovers();
    File(p).delete().ignore();
    await widget.reader.loadLibrary();
  }

  Future<void> _deleteForever(ShelfItem b) async {
    final t = widget.settings.theme;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: t.raisedSurface,
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
    onTap: () => _openBook(b),
    onDelete: () async {
      await widget.reader.delete(b.id);
      _categories.removeBook(b.id);
    },
    onDeleteForever: () => _deleteForever(b),
    onEncoding: () => _pickEncoding(b),
    onRename: () => _editInfo(b),
    onDrawCover: AppPlatformSupport.hasImageGen ? () => _drawCover(b) : null,
    onPin: () => _togglePin(b),
    onCategory: () => _chooseCategory(b),
  );

  Widget _coverCard(ShelfItem book) {
    final t = widget.settings.theme;
    void showActions() => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final action in <(String, VoidCallback)>[
                (book.pinned ? '取消置顶' : '置顶', () => _togglePin(book)),
                ('加入分类', () => _chooseCategory(book)),
                ('编辑信息', () => _editInfo(book)),
                if (AppPlatformSupport.hasImageGen)
                  ('AI 生成封面', () => _drawCover(book)),
                ('重新指定编码', () => _pickEncoding(book)),
                (
                  '删除',
                  () async {
                    await widget.reader.delete(book.id);
                    _categories.removeBook(book.id);
                  },
                ),
                ('彻底删除', () => _deleteForever(book)),
              ])
                ListTile(
                  title: Text(action.$1),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    action.$2();
                  },
                ),
            ],
          ),
        ),
      ),
    );
    return Tooltip(
      message: book.title,
      child: Material(
        color: t.surface,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _openBook(book),
          onLongPress: showActions,
          onSecondaryTap: showActions,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              children: [
                TextCover(
                  title: book.title,
                  hue: book.coverHue,
                  coverPath: book.coverPath,
                  width: 96,
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: Center(
                    child: Text(
                      book.title,
                      translate: false,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: t.text, fontSize: 13),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openBook(ShelfItem book) async {
    if (widget.settings.openBookToDetail) return _openBookDetail(book);
    await widget.reader.open(book.path);
    if (!mounted || !widget.reader.isOpen) return;
    widget.onOpened();
  }

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
      backgroundColor: t.raisedSurface,
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

  /// Reorders the shelf on drag-and-drop with immediate in-memory update (no
  /// snap-back flicker):
  /// - Dropping into the pinned zone pins the book at that slot.
  /// - Dragging a pinned book below the pinned zone unpins it at that slot.
  /// - Dragging among unpinned books persists the custom manual order.
  Future<void> _reorder(
    List<ShelfItem> books,
    int oldIndex,
    int newIndex,
  ) async {
    if (newIndex == oldIndex) return;
    final moved = books[oldIndex];
    final nextVisible = [...books]
      ..removeAt(oldIndex)
      ..insert(newIndex, moved);
    final visibleIds = {for (final b in books) b.id};
    var vi = 0;
    final nextFull = [
      for (final b in widget.reader.shelf)
        if (visibleIds.contains(b.id)) nextVisible[vi++] else b,
    ];

    final pinnedBefore = [
      for (final b in books)
        if (b.pinned && b.id != moved.id) b.id,
    ];
    final intoPinned =
        (pinnedBefore.isNotEmpty && newIndex < pinnedBefore.length) ||
        (moved.pinned && newIndex <= pinnedBefore.length);

    if (intoPinned) {
      final nextPinIds = [
        for (final b in nextFull)
          if (b.pinned || b.id == moved.id) b.id,
      ];
      widget.reader.applyShelfOrderLocally(nextFull);
      await setPinOrder(ids: Int64List.fromList(nextPinIds));
      await widget.reader.loadLibrary();
    } else if (moved.pinned) {
      final nextUnpinnedIds = [
        for (final b in nextFull)
          if (!b.pinned || b.id == moved.id) b.id,
      ];
      widget.reader.applyShelfOrderLocally(
        nextFull,
        manualUnpinnedOrder: nextUnpinnedIds,
      );
      await setBookPinned(bookId: moved.id, pinned: false);
      await widget.reader.loadLibrary();
    } else {
      final nextUnpinnedIds = [
        for (final b in nextFull)
          if (!b.pinned) b.id,
      ];
      widget.reader.applyShelfOrderLocally(
        nextFull,
        manualUnpinnedOrder: nextUnpinnedIds,
      );
    }
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
        backgroundColor: t.raisedSurface,
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
  final VoidCallback onDelete;
  final VoidCallback onDeleteForever;
  final VoidCallback onRename;

  /// Absent where covers cannot be drawn.
  final VoidCallback? onDrawCover;
  final VoidCallback onEncoding;
  final VoidCallback onPin;
  final VoidCallback onCategory;

  const BookCard({
    super.key,
    required this.item,
    required this.theme,
    required this.category,
    required this.onTap,
    required this.onDelete,
    required this.onDeleteForever,
    required this.onEncoding,
    required this.onRename,
    this.onDrawCover,
    required this.onPin,
    required this.onCategory,
  });

  @override
  Widget build(BuildContext context) {
    final read = item.chapterCount > 0
        ? (item.lastChapter + 1) / item.chapterCount
        : 0.0;
    final started = item.lastOpenedAt != null;
    final radius = BorderRadius.circular(14);
    return Material(
      color: theme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: theme.outline),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: Padding(
          padding: const EdgeInsets.all(12),
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
                            translate: false,
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
                              color: theme.muted.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: Text(
                              g,
                              style: TextStyle(
                                color: theme.muted,
                                fontSize: 10,
                              ),
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
                    const SizedBox(height: 10),
                    if (item.lastOpenedAt case final ts?) ...[
                      Text(
                        _formatLastRead(context, ts.toInt()),
                        translate: false,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: theme.muted,
                          fontSize: 11.5,
                          height: 1.3,
                        ),
                      ),
                      const SizedBox(height: 4),
                    ],

                    // The location is the latest stop, not the furthest chapter.
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
                                valueColor: AlwaysStoppedAnimation(
                                  Theme.of(context).colorScheme.primary,
                                ),
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
                            started
                                ? '${context.tr('读到')} ${item.lastChapterTitle.trim().isEmpty ? context.tr('第 ${item.lastChapter + 1} 章') : item.lastChapterTitle}'
                                : context.tr('尚未开始'),
                            translate: false,
                            style: TextStyle(
                              color: started ? theme.text : theme.muted,
                              fontSize: 13,
                              height: 1.4,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    if (windowsAppearance &&
                        started &&
                        (item.lastChapterSummary ?? '').trim().isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        item.lastChapterSummary!.trim(),
                        translate: false,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: theme.muted,
                          fontSize: 12,
                          height: 1.5,
                        ),
                      ),
                    ],
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
                  backgroundColor: theme.raisedSurface,
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
                          if (onDrawCover != null)
                            ListTile(
                              leading: Icon(
                                Icons.auto_awesome_outlined,
                                color: theme.text,
                              ),
                              title: Text(
                                'AI 生成封面',
                                style: TextStyle(color: theme.text),
                              ),
                              onTap: () {
                                Navigator.pop(ctx);
                                onDrawCover!();
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
      ),
    );
  }

  static String _formatLastRead(BuildContext context, int seconds) {
    final dt = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    final now = DateTime.now();
    final diff = now.difference(dt);
    String two(int v) => v.toString().padLeft(2, '0');
    final hm = '${two(dt.hour)}:${two(dt.minute)}';
    final prefix = context.tr('上次阅读');
    if (diff.isNegative) {
      return '$prefix ${dt.year}/${dt.month}/${dt.day} $hm';
    }
    if (diff.inSeconds < 60) {
      return '$prefix ${context.tr('刚刚')}';
    }
    if (diff.inMinutes < 60) {
      return '$prefix ${diff.inMinutes} ${context.tr('分钟前')}';
    }
    final today = DateTime(now.year, now.month, now.day);
    final date = DateTime(dt.year, dt.month, dt.day);
    final dayDiff = today.difference(date).inDays;
    if (dayDiff == 0) {
      return '$prefix ${context.tr('今天')} $hm';
    }
    if (dayDiff == 1) {
      return '$prefix ${context.tr('昨天')} $hm';
    }
    if (dt.year == now.year) {
      return '$prefix ${dt.month}/${dt.day} $hm';
    }
    return '$prefix ${dt.year}/${dt.month}/${dt.day}';
  }
}
