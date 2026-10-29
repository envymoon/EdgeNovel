import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel/plate_view.dart';
import 'package:novel/reader_state.dart';
import 'package:novel/src/rust/api/book.dart';
import 'package:novel/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _book = ShelfItem(
  id: 7,
  path: 'book.txt',
  title: '测试小说',
  chapterCount: 100,
  lastChapter: 0,
  lastOffset: 0,
  totalBytes: 1000,
  addedAt: 0,
  encoding: 'UTF-8',
  coverHue: 0,
  lastChapterTitle: '',
  pinned: false,
  genreTags: [],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'an unfinished job survives a restart, and cancelling drops it',
    () async {
      SharedPreferences.setMockInitialValues({'plates.every.v1': '{"7":20}'});
      final after = ReaderState();
      await after.initializeAiQueue();
      expect(after.plateEveryFor(_book.id), 20);
      expect(after.plateEveryFor(8), isNull);

      await after.cancelPlatesFor(_book.id);
      expect(after.plateEveryFor(_book.id), isNull);
      expect(after.plateStateFor(_book.id), AiTaskState.none);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('plates.every.v1'), '{}');
    },
  );

  testWidgets('a plate turns like a page', (tester) async {
    var forward = 0;
    var back = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlateView(
            path: 'missing.png',
            theme: ReadingSettings().theme,
            compactTapZones: false,
            onForward: () => forward++,
            onBack: () => back++,
          ),
        ),
      ),
    );
    final box = tester.getRect(find.byType(PlateView));
    await tester.tapAt(Offset(box.right - 10, box.center.dy));
    expect(forward, 1);
    await tester.tapAt(Offset(box.left + 10, box.center.dy));
    expect(back, 1);
  });
}
