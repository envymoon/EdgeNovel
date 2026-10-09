import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'platform_services.dart';
import 'youshu_parser.dart';

bool isYoushuUrl(Uri? uri) =>
    uri != null &&
    uri.scheme == 'https' &&
    ['youshu.me', 'www.youshu.me'].contains(uri.host) &&
    (!uri.hasPort || uri.port == 443);

const _youshuOrigin = 'https://www.youshu.me';

class YoushuSnapshot {
  final YoushuBook? book;
  final List<YoushuReview> reviews;
  final DateTime updated;
  final String? nextPath;
  final bool paginationVerified;
  const YoushuSnapshot(
    this.book,
    this.reviews,
    this.updated,
    this.nextPath, {
    this.paginationVerified = true,
  });
  Map<String, dynamic> toJson() => {
    'book': book == null
        ? null
        : {
            'id': book!.id,
            'title': book!.title,
            'author': book!.author,
            'ratings': book!.ratings.toJson(),
          },
    'reviews': reviews.map((e) => e.toJson()).toList(),
    'updated': updated.toIso8601String(),
    'next': nextPath,
    'paginationVersion': paginationVerified ? 1 : 0,
  };
  factory YoushuSnapshot.fromJson(Map<String, dynamic> j) {
    final b = j['book'] as Map<String, dynamic>?;
    return YoushuSnapshot(
      b == null
          ? null
          : YoushuBook(
              b['id'],
              b['title'],
              b['author'],
              ratings: b['ratings'] is Map
                  ? YoushuRatings.fromJson(
                      Map<String, dynamic>.from(b['ratings'] as Map),
                    )
                  : const YoushuRatings(),
            ),
      (j['reviews'] as List)
          .map((e) => YoushuReview.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      DateTime.parse(j['updated'] as String),
      j['next'] as String?,
      paginationVerified: j['paginationVersion'] == 1,
    );
  }
}

/// WebView owns the session. Credentials/cookies are never copied to app JSON.
/// Views are created only for login or a user-requested review fetch.
class YoushuService {
  YoushuService._();
  static final instance = YoushuService._();
  Future<WebViewEnvironment?>? _environment;
  Future<void> _tail = Future.value();

  Future<WebViewEnvironment?> environment() {
    return _environment ??= _createEnvironment().catchError((Object e) {
      _environment = null;
      throw e;
    });
  }

  Future<WebViewEnvironment?> _createEnvironment() async {
    if (!Platform.isWindows) return null;
    if (await WebViewEnvironment.getAvailableVersion() == null) {
      throw const YoushuException('需要 Microsoft Edge WebView2 Runtime 才能打开优书网');
    }
    final dir = AppServices.instance.storage.supportChild('youshu_webview');
    await dir.create(recursive: true);
    return WebViewEnvironment.create(
      settings: WebViewEnvironmentSettings(userDataFolder: dir.path),
    );
  }

  Future<bool> get enabled async =>
      (await SharedPreferences.getInstance()).getBool('youshuEnabled') ?? false;
  Future<void> setEnabled(bool value) async {
    await (await SharedPreferences.getInstance()).setBool(
      'youshuEnabled',
      value,
    );
  }

  Future<void> clearLogin() async {
    await setEnabled(false);
    final cookies = CookieManager.instance(
      webViewEnvironment: await environment(),
    );
    for (final host in ['youshu.me', 'www.youshu.me']) {
      final url = WebUri('https://$host/');
      for (final cookie in await cookies.getCookies(url: url)) {
        await cookies.deleteCookie(
          url: url,
          name: cookie.name,
          domain: cookie.domain,
          path: cookie.path ?? '/',
        );
      }
    }
  }

  String _key(String title, String? author) =>
      'youshu.v1.${sha256.convert(utf8.encode('$title\u0000${author ?? ''}'))}';
  Future<YoushuSnapshot?> cached(String title, String? author) async {
    final raw = (await SharedPreferences.getInstance()).getString(
      _key(title, author),
    );
    if (raw == null) return null;
    try {
      final snapshot = YoushuSnapshot.fromJson(jsonDecode(raw));
      return snapshot.book == null ? null : snapshot;
    } catch (_) {
      return null;
    }
  }

  Future<YoushuSnapshot?> refresh(
    String title,
    String? author, {
    bool force = false,
  }) async {
    final existing = await cached(title, author);
    if (!force && existing != null) return existing;
    if (!await enabled) throw const YoushuException('请先登录优书网');
    final key = _key(title, author);
    return _serial(() async {
      try {
        YoushuBook? book = existing?.book;
        if (book == null) {
          Uri? resolvedSearchUrl;
          final source = await _read(
            '/search/all/${Uri.encodeComponent(title.trim())}/1.html',
            onFinalUrl: (url) => resolvedSearchUrl = url,
          );
          final resolvedId = youshuBookIdFromUri(resolvedSearchUrl);
          final ids = resolvedId == null
              ? matchingYoushuBookIds(source, title)
              : <String>[resolvedId];
          if (ids.length > 5) {
            throw const YoushuException('同名书籍较多，请补全本地书籍作者后重试');
          }
          final matches = <YoushuBook>[];
          final mismatches = <String>[];
          for (final id in ids) {
            final candidate = parseYoushuBook(await _read('/book/$id'), id);
            if (normalizeYoushuTitle(candidate.title) !=
                normalizeYoushuTitle(title)) {
              mismatches.add('站内书名：${candidate.title}');
              continue;
            }
            if (author != null &&
                author.trim().isNotEmpty &&
                author != '佚名' &&
                normalizeYoushuTitle(candidate.author) !=
                    normalizeYoushuTitle(author)) {
              mismatches.add('站内作者：${candidate.author}；本地作者：$author');
              continue;
            }
            matches.add(candidate);
          }
          if (matches.length > 1) {
            throw const YoushuException('存在同名书籍，请补全本地书籍作者后重试');
          }
          if (matches.isEmpty && mismatches.isNotEmpty) {
            throw YoushuException('已找到候选书籍，但信息不一致。${mismatches.join('；')}');
          }
          book = matches.firstOrNull;
        } else {
          // A manual refresh also refreshes the site's live rating. Preserve
          // the verified match before replacing cached metadata.
          final refreshed = parseYoushuBook(
            await _read('/book/${book.id}'),
            book.id,
          );
          if (normalizeYoushuTitle(refreshed.title) !=
                  normalizeYoushuTitle(book.title) ||
              normalizeYoushuTitle(refreshed.author) !=
                  normalizeYoushuTitle(book.author)) {
            throw const YoushuException('优书网书籍信息发生变化，已保留本地缓存');
          }
          book = refreshed;
        }
        YoushuSnapshot result;
        if (book == null) {
          // A failed lookup is not proof that the book has no reviews.  In
          // particular, Youshu may redirect a request to a login or changed
          // search page.  Never turn that state into a persistent empty
          // review result.
          throw const YoushuException('优书网未找到同名书籍，请检查本地书名');
        } else {
          final parsed = parseYoushuReviews(
            await _read('/reviews/${book.id}/1.html'),
            book.id,
          );
          result = YoushuSnapshot(
            book,
            mergeReviews(parsed.reviews, existing?.reviews ?? const []),
            DateTime.now(),
            nextAfterRefresh(existing, parsed.nextPath),
          );
        }
        await (await SharedPreferences.getInstance()).setString(
          key,
          jsonEncode(result.toJson()),
        );
        return result;
      } catch (_) {
        rethrow;
      }
    });
  }

  static List<YoushuReview> mergeReviews(
    List<YoushuReview> latest,
    List<YoushuReview> saved,
  ) {
    final byId = {for (final review in latest) review.id: review};
    for (final review in saved) {
      byId.putIfAbsent(review.id, () => review);
    }
    return byId.values.toList();
  }

  /// Updating the newest page must not discard an unfinished older-page cursor.
  static String? nextAfterRefresh(
    YoushuSnapshot? existing,
    String? firstPageNext,
  ) =>
      existing?.paginationVerified == true ? existing!.nextPath : firstPageNext;

  Future<YoushuSnapshot> loadMore(String title, String? author) =>
      _serial(() async {
        final saved = await cached(title, author);
        if (saved == null || saved.book == null || saved.nextPath == null) {
          throw const YoushuException('没有更多书评');
        }
        if (!await enabled) throw const YoushuException('请先登录优书网');
        final match = RegExp(
          r'^/reviews/(\d+)/(\d+)\.html$',
        ).firstMatch(saved.nextPath!);
        if (match == null || match.group(1) != saved.book!.id) {
          throw const YoushuException('无效的书评分页');
        }
        final page = parseYoushuReviews(
          await _read(saved.nextPath!),
          saved.book!.id,
          page: int.parse(match.group(2)!),
        );
        final result = YoushuSnapshot(
          saved.book,
          mergeReviews(saved.reviews, page.reviews),
          saved.updated,
          page.nextPath,
        );
        await (await SharedPreferences.getInstance()).setString(
          _key(title, author),
          jsonEncode(result.toJson()),
        );
        return result;
      });

  Future<T> _serial<T>(Future<T> Function() work) {
    final result = _tail.then((_) => work());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<String> _read(
    String path, {
    void Function(Uri url)? onFinalUrl,
  }) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await _readOnce(path, onFinalUrl: onFinalUrl);
      } on YoushuException catch (error) {
        final retryable =
            error.message.contains('连接失败') ||
            error.message.contains('连接超时') ||
            RegExp(r'HTTP (429|5\d\d)').hasMatch(error.message);
        if (!retryable || attempt >= 3) rethrow;
        await Future<void>.delayed(Duration(seconds: [5, 15, 30][attempt]));
      }
    }
  }

  Future<String> _readOnce(
    String path, {
    void Function(Uri url)? onFinalUrl,
  }) async {
    // Youshu's login form posts to www.youshu.me.  Starting background
    // requests on the bare host can omit a host-only login cookie, making a
    // successfully logged-in user appear anonymous to search.
    final url = WebUri('$_youshuOrigin$path');
    if (!isYoushuUrl(url)) throw const YoushuException('无效的优书网地址');
    final done = Completer<String>();
    void fail([String message = '优书网连接失败，请稍后重试']) {
      if (!done.isCompleted) {
        done.completeError(YoushuException(message));
      }
    }

    final view = HeadlessInAppWebView(
      webViewEnvironment: await environment(),
      initialUrlRequest: URLRequest(url: url),
      initialSettings: InAppWebViewSettings(
        useShouldOverrideUrlLoading: true,
        mediaPlaybackRequiresUserGesture: true,
        javaScriptCanOpenWindowsAutomatically: false,
        supportMultipleWindows: true,
      ),
      shouldOverrideUrlLoading: (_, navigation) async =>
          navigation.isForMainFrame && !isYoushuUrl(navigation.request.url)
          ? NavigationActionPolicy.CANCEL
          : NavigationActionPolicy.ALLOW,
      onCreateWindow: (_, _) async => false,
      onPermissionRequest: (_, request) async => PermissionResponse(
        resources: request.resources,
        action: PermissionResponseAction.DENY,
      ),
      onReceivedError: (_, request, _) {
        if (request.isForMainFrame == true) fail();
      },
      onReceivedHttpError: (_, request, response) {
        if (request.isForMainFrame == true) {
          fail('优书网返回 HTTP ${response.statusCode}，已保留下载进度');
        }
      },
      onLoadStop: (controller, current) async {
        if (done.isCompleted || !isYoushuUrl(current)) return;
        try {
          onFinalUrl?.call(current!);
          final source = await controller.evaluateJavascript(
            source: 'document.documentElement.outerHTML',
          );
          if (!done.isCompleted) {
            if (source is String && source.length < 2000000) {
              done.complete(source);
            } else {
              fail();
            }
          }
        } catch (_) {
          fail();
        }
      },
    );
    // Attach the timeout handler before navigation can report an error.
    final response = done.future.timeout(
      const Duration(seconds: 25),
      onTimeout: () => throw const YoushuException('优书网连接超时'),
    );
    var released = false;
    try {
      unawaited(
        view
            .run()
            .then((_) async {
              if (released) await view.dispose();
            })
            .catchError((Object _) {
              fail();
            }),
      );
      return await response;
    } finally {
      released = true;
      if (!done.isCompleted) done.complete('');
      await view.dispose();
    }
  }
}
