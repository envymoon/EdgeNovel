import 'package:flutter_test/flutter_test.dart';
import 'package:novel/reading_session_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('active reader route survives restart until the user leaves', () async {
    SharedPreferences.setMockInitialValues({});
    final first = await ReadingSessionStore.load();
    expect(first.activeBookPath, isNull);

    await first.remember(r'C:\books\novel.txt');
    final restarted = await ReadingSessionStore.load();
    expect(restarted.activeBookPath, r'C:\books\novel.txt');

    await restarted.clear();
    expect((await ReadingSessionStore.load()).activeBookPath, isNull);
  });
}
