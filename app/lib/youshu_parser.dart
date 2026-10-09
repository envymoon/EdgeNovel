import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;

class YoushuException implements Exception {
  final String message;
  const YoushuException(this.message);
  @override
  String toString() => message;
}

class YoushuReview {
  final String id;
  final String content;
  final String date;
  final int? stars;
  final bool excerpt;
  const YoushuReview({
    required this.id,
    required this.content,
    required this.date,
    this.stars,
    this.excerpt = false,
  });
  Map<String, dynamic> toJson() => {
    'id': id,
    'content': content,
    'date': date,
    'stars': stars,
    'excerpt': excerpt,
  };
  factory YoushuReview.fromJson(Map<String, dynamic> j) => YoushuReview(
    id: j['id'] as String,
    content: j['content'] as String,
    date: j['date'] as String,
    stars: j['stars'] as int?,
    excerpt: j['excerpt'] == true,
  );
}

class YoushuBook {
  final String id;
  final String title;
  final String author;
  final YoushuRatings ratings;
  const YoushuBook(
    this.id,
    this.title,
    this.author, {
    this.ratings = const YoushuRatings(),
  });
}

class YoushuRating {
  final double score;
  final int count;
  const YoushuRating(this.score, this.count);

  Map<String, dynamic> toJson() => {'score': score, 'count': count};
  factory YoushuRating.fromJson(Map<String, dynamic> json) =>
      YoushuRating((json['score'] as num).toDouble(), json['count'] as int);
}

class YoushuRatings {
  final YoushuRating? current;
  final YoushuRating? archived;
  const YoushuRatings({this.current, this.archived});

  Map<String, dynamic> toJson() => {
    'current': current?.toJson(),
    'archived': archived?.toJson(),
  };
  factory YoushuRatings.fromJson(Map<String, dynamic> json) {
    final current = json['current'];
    final archived = json['archived'];
    return YoushuRatings(
      current: current is Map
          ? YoushuRating.fromJson(Map<String, dynamic>.from(current))
          : null,
      archived: archived is Map
          ? YoushuRating.fromJson(Map<String, dynamic>.from(archived))
          : null,
    );
  }
}

YoushuRatings parseYoushuRatings(Document doc) {
  YoushuRating? rating(String? scoreText, String? countText) {
    final score = double.tryParse(scoreText?.trim() ?? '');
    final count = int.tryParse(
      RegExp(
            r'\d[\d,]*',
          ).firstMatch(countText ?? '')?.group(0)?.replaceAll(',', '') ??
          '',
    );
    if (score == null ||
        score < 0 ||
        score > 10 ||
        count == null ||
        count < 0) {
      return null;
    }
    return YoushuRating(score, count);
  }

  final live = doc.querySelector('#download-review-over-view');
  final archived = doc.querySelector('#project-desc .book-score-overview');
  return YoushuRatings(
    current: rating(
      live?.querySelector('.star-rating-average')?.text,
      live?.querySelector('.star-rating-summary span.color-1')?.text,
    ),
    archived: rating(
      archived?.querySelector('.score')?.text,
      archived?.querySelector('.scorer-count')?.text,
    ),
  );
}

class YoushuReviewPage {
  final List<YoushuReview> reviews;
  final String? nextPath;
  const YoushuReviewPage(this.reviews, this.nextPath);
}

String normalizeYoushuTitle(String value) =>
    value.replaceAll(RegExp(r'[\s\u3000《》]'), '').toLowerCase();

String? youshuBookIdFromUri(Uri? uri) {
  if (uri == null ||
      (uri.hasAuthority &&
          !['youshu.me', 'www.youshu.me'].contains(uri.host))) {
    return null;
  }
  final rewritten = RegExp(r'^/book/(\d+)(?:\.html)?/?$').firstMatch(uri.path);
  if (rewritten != null) return rewritten.group(1);
  if (uri.path.endsWith('/modules/article/articleinfo.php')) {
    final id = uri.queryParameters['id'];
    if (id != null && RegExp(r'^\d+$').hasMatch(id)) return id;
  }
  return null;
}

Document checkedYoushuDocument(String source) {
  final doc = html.parse(source);
  // The small header login form exists on public book pages too.
  if (doc.querySelector(
            'form[name="frmlogin"], form#t_frmlogin, form[action*="login"]',
          ) !=
          null ||
      doc.querySelector('legend')?.text.trim() == '用户登录') {
    throw const YoushuException('请先登录优书网，或重新登录');
  }
  if (doc.querySelector('#content') == null ||
      doc.querySelector('#challenge-running') != null) {
    throw const YoushuException('优书网暂时无法读取，请在登录页完成验证后重试');
  }
  return doc;
}

YoushuBook parseYoushuBook(String source, String id) {
  final doc = checkedYoushuDocument(source);
  final pageTitle = doc.querySelector('title')?.text.trim() ?? '';
  final authorNodes = doc.querySelectorAll(
    'a[href*="authorarticle.php"], a[href*="/author/"], '
    'a[href*="author="]',
  );
  // Navigation links ("作者专栏", "更多...") precede the actual byline.
  // Their author query parameter identifies the author; their label does not.
  var author =
      authorNodes
          .where(
            (node) => RegExp(r'作者\s*[：:]').hasMatch(node.parent?.text ?? ''),
          )
          .map((node) => node.text.trim())
          .where((text) => text.isNotEmpty && text != '作者专栏')
          .firstOrNull ??
      '';
  for (final node in authorNodes) {
    if (author.isNotEmpty) break;
    final uri = Uri.tryParse(node.attributes['href'] ?? '');
    final parameter = uri?.queryParameters['author']?.trim();
    final label = node.text.trim();
    if (parameter != null && parameter.isNotEmpty) {
      author = parameter;
      break;
    }
    if (label.isNotEmpty && !RegExp(r'作者专栏|更多|本$').hasMatch(label)) {
      author = label;
      break;
    }
  }
  if (author.isEmpty) {
    author =
        RegExp(r'作者\s*[：:]\s*([^\s|｜]+)')
            .firstMatch(doc.querySelector('#content')?.text ?? '')
            ?.group(1)
            ?.trim() ??
        '';
  }

  var title = pageTitle.replaceFirst(RegExp(r'\s*[-–—|｜]\s*优书网.*$'), '').trim();
  if (author.isNotEmpty) {
    title = title
        .replaceFirst(
          RegExp(
            '${RegExp.escape(author)}\\s*'
            r'$',
          ),
          '',
        )
        .replaceFirst(RegExp(r'\s*[-–—|｜]\s*$'), '')
        .trim();
  }
  if (title.isEmpty || author.isEmpty) {
    throw const YoushuException('无法确认优书网书籍信息');
  }
  return YoushuBook(id, title, author, ratings: parseYoushuRatings(doc));
}

List<String> matchingYoushuBookIds(String source, String title) {
  final doc = checkedYoushuDocument(source);
  final ids = <String>{};
  for (final a in doc.querySelectorAll('#content a[href]')) {
    final uri = Uri.tryParse(a.attributes['href'] ?? '');
    if (uri == null ||
        (uri.hasAuthority &&
            !['youshu.me', 'www.youshu.me'].contains(uri.host))) {
      continue;
    }
    final id = youshuBookIdFromUri(uri);
    if (id != null &&
        normalizeYoushuTitle(a.text) == normalizeYoushuTitle(title)) {
      ids.add(id);
    }
  }
  // A generic "搜索" in the header is not proof that the result is empty.
  // Unknown markup must never be persisted as "this book has no reviews".
  if (ids.isEmpty &&
      !RegExp(
        r'(没有|未|无法|暂无).{0,8}(找到|搜到|搜索结果|相关书籍)|0\s*(条|个)搜索结果',
      ).hasMatch(doc.querySelector('#content')!.text)) {
    throw const YoushuException('优书网搜索页面发生变化，请稍后重试');
  }
  return ids.toList();
}

String _plain(Element element) {
  final copy = element.clone(true);
  for (final node in copy.querySelectorAll('script, style, .c_all')) {
    node.remove();
  }
  for (final br in copy.querySelectorAll('br')) {
    br.replaceWith(Text('\n'));
  }
  for (final image in copy.querySelectorAll('img[alt]')) {
    image.replaceWith(Text(image.attributes['alt'] ?? ''));
  }
  return copy.text.trim();
}

YoushuReviewPage parseYoushuReviews(
  String source,
  String bookId, {
  int page = 1,
}) {
  final doc = checkedYoushuDocument(source);
  final reviews = <String, YoushuReview>{};
  for (final row in doc.querySelectorAll('.c_row')) {
    final link = row.querySelector('.c_subject a[href*="/reviewshow/"]');
    final id = RegExp(
      r'/reviewshow/(\d+)/',
    ).firstMatch(link?.attributes['href'] ?? '')?.group(1);
    final content = row.querySelector('.c_description');
    if (id == null || content == null) continue;
    final text = _plain(content);
    if (text.isEmpty) continue;
    final date =
        RegExp(
          r'时间：\s*(\d{4}-\d{2}-\d{2}(?:\s+\d{2}:\d{2}:\d{2})?)',
        ).firstMatch(row.querySelector('.c_tag')?.text ?? '')?.group(1) ??
        '';
    final stars = int.tryParse(
      RegExp(r'([1-5])\s*颗星')
              .firstMatch(
                row.querySelector('.c_subject [title]')?.attributes['title'] ??
                    '',
              )
              ?.group(1) ??
          '',
    );
    reviews[id] = YoushuReview(
      id: id,
      content: text,
      date: date,
      stars: stars,
      excerpt: content.querySelector('.c_all') != null,
    );
  }
  String? next;
  for (final a in doc.querySelectorAll('a[href]')) {
    final uri = Uri.tryParse(a.attributes['href']!);
    if (uri == null ||
        (uri.hasAuthority &&
            !['youshu.me', 'www.youshu.me'].contains(uri.host))) {
      continue;
    }
    final match = RegExp(
      '^/reviews/$bookId/(\\d+)\\.html\$',
    ).firstMatch(uri.path);
    final legacy =
        uri.path == '/modules/article/reviews.php' &&
        uri.queryParameters['aid'] == bookId &&
        !uri.queryParameters.containsKey('type');
    final linkedPage = match != null
        ? int.tryParse(match.group(1)!)
        : legacy
        ? int.tryParse(uri.queryParameters['page'] ?? '')
        : null;
    if (linkedPage == page + 1) {
      next = '/reviews/$bookId/$linkedPage.html';
    }
  }
  if (reviews.isEmpty &&
      !RegExp(
        r'(暂无|尚无|没有).{0,8}(书评|评论)|共\s*0\s*篇',
      ).hasMatch(doc.querySelector('#content')!.text)) {
    throw const YoushuException('未能解析书评，请在优书网确认页面');
  }
  return YoushuReviewPage(reviews.values.toList(), next);
}
