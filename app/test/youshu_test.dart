import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:novel/youshu_parser.dart';
import 'package:novel/youshu_service.dart';
import 'package:novel/youshu_reviews.dart';
import 'package:novel/theme.dart';

const review = YoushuReview(id: '1', content: '测试书评', date: '2020-01-01');
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('old cache is reused indefinitely even while logged in', () async {
    final snapshot = YoushuSnapshot(
      const YoushuBook('1', '测试', '作者'),
      [review],
      DateTime(2020),
      '/reviews/1/2.html',
    );
    final key = 'youshu.v1.${sha256.convert(utf8.encode('测试\u0000作者'))}';
    SharedPreferences.setMockInitialValues({
      'youshuEnabled': true,
      key: jsonEncode(snapshot.toJson()),
    });
    final result = await YoushuService.instance.refresh('测试', '作者');
    expect(result!.reviews.single.content, review.content);
    expect(result.nextPath, '/reviews/1/2.html');
  });
  test('refresh retains older pages and updates duplicate IDs', () {
    const changed = YoushuReview(id: '1', content: '更新', date: '');
    const older = YoushuReview(id: '2', content: '旧分页', date: '');
    final merged = YoushuService.mergeReviews([changed], [review, older]);
    expect(merged.map((e) => e.content), ['更新', '旧分页']);
  });
  test('refresh keeps an unfinished pagination cursor', () {
    final saved = YoushuSnapshot(
      const YoushuBook('1', '测试', '作者'),
      [review],
      DateTime(2020),
      '/reviews/1/14.html',
    );
    expect(
      YoushuService.nextAfterRefresh(saved, '/reviews/1/2.html'),
      '/reviews/1/14.html',
    );
    final complete = YoushuSnapshot(
      saved.book,
      saved.reviews,
      saved.updated,
      null,
    );
    expect(
      YoushuService.nextAfterRefresh(complete, '/reviews/1/2.html'),
      isNull,
    );
  });
  test('an unmatched book is distinct from a confirmed empty review page', () {
    final unmatched = YoushuSnapshot(null, const [], DateTime(2020), null);
    final empty = YoushuSnapshot(
      const YoushuBook('1', '测试', '作者'),
      const [],
      DateTime(2020),
      null,
    );
    expect(unmatched.book, isNull);
    expect(empty.book, isNotNull);
  });
  test('login and malformed pages are not empty results', () {
    expect(
      () => parseYoushuReviews('<form name="frmlogin"></form>', '1'),
      throwsA(isA<YoushuException>()),
    );
    expect(
      () => parseYoushuReviews('<div id="content">changed</div>', '1'),
      throwsA(isA<YoushuException>()),
    );
    expect(
      parseYoushuReviews('<div id="content">暂无书评</div>', '1').reviews,
      isEmpty,
    );
  });
  test('book parser accepts current and layout-tolerant metadata', () {
    final current = parseYoushuBook('''
      <div id="content">
        <div>诡秘之主 作者：<a href="/modules/article/authorarticle.php?author=x">爱潜水的乌贼</a></div>
      </div>
      <title>诡秘之主-爱潜水的乌贼-优书网</title>
    ''', '141152');
    expect(current.title, '诡秘之主');
    expect(current.author, '爱潜水的乌贼');

    final fallback = parseYoushuBook('''
      <div id="content"><div>异兽迷城　作者：彭湃</div></div>
      <title>异兽迷城 | 彭湃 | 优书网</title>
    ''', '2');
    expect(fallback.title, '异兽迷城');
    expect(fallback.author, '彭湃');
  });
  test('real page navigation is not mistaken for the author byline', () {
    final book = parseYoushuBook('''
      <title>诡秘之主-爱潜水的乌贼-优书网</title>
      <div id="content">
        <ul><li><a href="/modules/article/authorarticle.php?author=%E7%88%B1%E6%BD%9C%E6%B0%B4%E7%9A%84%E4%B9%8C%E8%B4%BC">作者专栏</a></li></ul>
        <span>作者：<a href="/modules/article/authorarticle.php?author=%E7%88%B1%E6%BD%9C%E6%B0%B4%E7%9A%84%E4%B9%8C%E8%B4%BC">爱潜水的乌贼</a></span>
      </div>
    ''', '141152');
    expect(book.title, '诡秘之主');
    expect(book.author, '爱潜水的乌贼');
  });
  test('live and archived ratings are parsed separately', () {
    final book = parseYoushuBook('''
      <title>诡秘之主-爱潜水的乌贼-优书网</title>
      <div id="content">
        <span>作者：<a href="/author/x">爱潜水的乌贼</a></span>
        <div id="download-review-over-view">
          <div class="star-rating-summary">
            <div class="star-rating-average color-1">8.8</div>
            <div><span class="color-1">8272</span> 评分次数</div>
          </div>
        </div>
        <div id="project-desc"><div class="book-score-overview">
          <p class="score">8.8</p><p class="scorer-count">8156个评分</p>
        </div></div>
      </div>
    ''', '141152');
    expect(book.ratings.current?.score, 8.8);
    expect(book.ratings.current?.count, 8272);
    expect(book.ratings.archived?.score, 8.8);
    expect(book.ratings.archived?.count, 8156);
    final restored = YoushuSnapshot.fromJson(
      YoushuSnapshot(book, const [], DateTime(2026), null).toJson(),
    );
    expect(restored.book?.ratings.current?.count, 8272);
    expect(restored.book?.ratings.archived?.count, 8156);
  });
  test('old cached books without ratings remain readable', () {
    final restored = YoushuSnapshot.fromJson({
      'book': {'id': '1', 'title': '测试', 'author': '作者'},
      'reviews': [],
      'updated': DateTime(2020).toIso8601String(),
      'next': null,
    });
    expect(restored.book?.ratings.current, isNull);
    expect(restored.book?.ratings.archived, isNull);
  });
  test('search parser accepts rewritten and legacy book links', () {
    final ids = matchingYoushuBookIds('''
      <div id="content">
        <a href="/book/141152">诡秘之主</a>
        <a href="/modules/article/articleinfo.php?id=141152">诡秘之主</a>
        <a href="https://www.youshu.me/modules/article/articleinfo.php?id=2">其他书</a>
      </div>
    ''', '诡秘之主');
    expect(ids, ['141152']);
    expect(
      youshuBookIdFromUri(Uri.parse('https://youshu.me/book/141152')),
      '141152',
    );
    expect(
      youshuBookIdFromUri(
        Uri.parse(
          'https://www.youshu.me/modules/article/articleinfo.php?id=141152',
        ),
      ),
      '141152',
    );
  });
  test('unknown search markup is not treated as an empty result', () {
    expect(
      () => matchingYoushuBookIds(
        '<div id="content"><form>搜索</form><div>changed</div></div>',
        '诡秘之主',
      ),
      throwsA(isA<YoushuException>()),
    );
    expect(
      matchingYoushuBookIds('<div id="content">没有找到相关书籍</div>', '不存在'),
      isEmpty,
    );
  });
  test('parser excludes reviewer identity', () {
    final parsed = parseYoushuReviews('''<div id="content"><div class="c_row">
      <div class="username">不应保存的用户名</div>
      <div class="c_subject"><a href="/reviewshow/1/1.html">标题</a></div>
      <div class="c_description">第一段<br>第二段<a class="c_all">全文</a></div>
      </div><a href="/reviews/1/2.html">下一页</a></div>''', '1');
    expect(parsed.reviews.single.content, '第一段\n第二段');
    expect(jsonEncode(parsed.reviews.single.toJson()), isNot(contains('用户名')));
    expect(parsed.reviews.single.toJson().containsKey('title'), isFalse);
    expect(parsed.nextPath, '/reviews/1/2.html');
  });
  test('old cached review titles are ignored without losing the body', () {
    final migrated = YoushuReview.fromJson({
      'id': '1',
      'title': '与正文首行重复',
      'content': '与正文首行重复\n正文',
      'date': '',
      'stars': null,
      'excerpt': false,
    });
    expect(migrated.content, '与正文首行重复\n正文');
    expect(migrated.toJson().containsKey('title'), isFalse);
  });
  testWidgets('cached review renders its body once without the old title', (
    tester,
  ) async {
    final settings = await ReadingSettings.load();
    final old = YoushuReview.fromJson({
      'id': '1',
      'title': '重复的第一行',
      'content': '重复的第一行\n正文',
      'date': '',
      'stars': null,
      'excerpt': false,
    });
    await tester.pumpWidget(
      MaterialApp(
        home: YoushuReviewsPage(
          title: '测试书',
          settings: settings,
          initial: YoushuSnapshot(
            const YoushuBook('1', '测试书', '作者'),
            [old],
            DateTime(2020),
            null,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('重复的第一行'), findsNothing);
    expect(find.text('重复的第一行\n正文'), findsOneWidget);
  });
  testWidgets('current and archived scores keep distinct labels', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: YoushuRatingsView(
            ratings: YoushuRatings(
              current: YoushuRating(8.8, 8272),
              archived: YoushuRating(8.8, 8156),
            ),
          ),
        ),
      ),
    );
    expect(find.text('youshu.me 现行 8.8/10 · 8272 人'), findsOneWidget);
    expect(find.text('旧优书存档 8.8/10 · 8156 人'), findsOneWidget);
  });
  test(
    'legacy pagination follows same book and does not follow sorting links',
    () {
      const rows =
          '<div id="content"><div class="c_row"><div class="c_subject"><a href="/reviewshow/1/1.html">标题</a></div><div class="c_description">书评</div></div>';
      final result = parseYoushuReviews('''$rows
      <a href="/modules/article/reviews.php?aid=141152&amp;page=1">1</a>
      <a href="/modules/article/reviews.php?aid=141152&amp;page=2">2</a>
      <a href="/modules/article/reviews.php?aid=141152&amp;page=170">末页</a>
      <a href="/modules/article/reviews.php?aid=2&amp;page=2">其他书</a>
      <a href="/modules/article/reviews.php?aid=141152&amp;page=2&amp;type=good">排序</a>
      </div>''', '141152');
      expect(result.nextPath, '/reviews/141152/2.html');
      expect(
        parseYoushuReviews('$rows</div>', '141152', page: 170).nextPath,
        isNull,
      );
    },
  );
  test('old first-page cache does not claim pagination is complete', () {
    final json = YoushuSnapshot(
      const YoushuBook('1', '测试', '作者'),
      [review],
      DateTime(2020),
      null,
    ).toJson()..remove('paginationVersion');
    expect(YoushuSnapshot.fromJson(json).paginationVerified, isFalse);
  });
  testWidgets('book entry does not load reviews', (tester) async {
    SharedPreferences.setMockInitialValues({'youshuEnabled': true});
    final settings = await ReadingSettings.load();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: YoushuReviewEntry(title: '测试', settings: settings),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
