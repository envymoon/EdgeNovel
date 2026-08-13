import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel/model_download.dart';

void main() {
  late Directory directory;
  late HttpServer server;
  late Uint8List content;
  final requestedRanges = <String?>[];

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('novel_download_test_');
    content = Uint8List.fromList(
      List<int>.generate(512 * 1024, (index) => index % 251),
    );
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final range = request.headers.value(HttpHeaders.rangeHeader);
      requestedRanges.add(range);
      final start = range == null
          ? 0
          : int.parse(RegExp(r'bytes=([0-9]+)-').firstMatch(range)!.group(1)!);
      if (start >= content.length) {
        request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        await request.response.close();
        return;
      }
      if (start > 0) {
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-${content.length - 1}/${content.length}',
        );
      }
      request.response.contentLength = content.length - start;
      try {
        for (var offset = start; offset < content.length; offset += 8192) {
          final end = (offset + 8192).clamp(0, content.length);
          request.response.add(content.sublist(offset, end));
          await request.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        await request.response.close();
      } catch (_) {
        // A paused client intentionally closes this response.
      }
    });
  });

  tearDown(() async {
    await server.close(force: true);
    await directory.delete(recursive: true);
  });

  test('pause preserves bytes and the next run resumes with Range', () async {
    final target = File('${directory.path}${Platform.pathSeparator}model.gguf');
    final url = 'http://${server.address.host}:${server.port}/model';
    final first = ResumableFileDownload();
    var pauseSent = false;

    await expectLater(
      first.downloadFirst(
        [url],
        target,
        onProgress: (received, _) {
          if (!pauseSent && received >= 64 * 1024) {
            pauseSent = true;
            first.pause();
          }
        },
      ),
      throwsA(
        isA<DownloadStopped>().having(
          (error) => error.kind,
          'kind',
          DownloadStopKind.paused,
        ),
      ),
    );

    final partial = ResumableFileDownload.partialFile(target);
    expect(await partial.exists(), isTrue);
    final kept = await partial.length();
    expect(kept, greaterThan(0));
    expect(kept, lessThan(content.length));

    await ResumableFileDownload().downloadFirst(
      [url],
      target,
      onProgress: (_, _) {},
    );

    expect(await target.readAsBytes(), content);
    expect(requestedRanges.whereType<String>(), contains('bytes=$kept-'));
  });

  test('cancel removes completed and partial download files', () async {
    final target = File('${directory.path}${Platform.pathSeparator}model.gguf');
    final partial = ResumableFileDownload.partialFile(target);
    await target.writeAsBytes([1, 2, 3]);
    await partial.writeAsBytes([4, 5, 6]);

    await ResumableFileDownload.discard(target);

    expect(await target.exists(), isFalse);
    expect(await partial.exists(), isFalse);
  });

  test(
    'cancelling an active transfer waits for the file handle to close',
    () async {
      final target = File(
        '${directory.path}${Platform.pathSeparator}model.gguf',
      );
      final url = 'http://${server.address.host}:${server.port}/model';
      final transfer = ResumableFileDownload();
      Future<void>? cancellation;

      await expectLater(
        transfer.downloadFirst(
          [url],
          target,
          onProgress: (received, _) {
            if (received >= 64 * 1024 && cancellation == null) {
              cancellation = transfer.cancel(target);
            }
          },
        ),
        throwsA(
          isA<DownloadStopped>().having(
            (error) => error.kind,
            'kind',
            DownloadStopKind.cancelled,
          ),
        ),
      );
      await cancellation;

      expect(await target.exists(), isFalse);
      expect(await ResumableFileDownload.partialFile(target).exists(), isFalse);
    },
  );
}
