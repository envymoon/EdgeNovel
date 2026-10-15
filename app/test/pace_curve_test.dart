import 'package:flutter_test/flutter_test.dart';
import 'package:novel/pace_page.dart';

void main() {
  test('smoothing skips unmeasured chapters instead of counting them as 0', () {
    final c = PaceCurve([1.0, null, 3.0, null, null, null, null]);
    expect(c.smooth(1), [1.0, 2.0, 3.0, 3.0, null, null, null]);
  });

  test('one long battle is one peak, named by its most intense chapter', () {
    final raw = <double?>[
      for (var i = 0; i < 400; i++)
        i >= 100 && i < 130
            ? (i == 117 ? 4.0 : 2.0)
            : i >= 300 && i < 320
            ? 1.5
            : 0.0,
    ];
    final peaks = PaceCurve(raw).peaks();
    expect(peaks.where((p) => p >= 100 && p < 130), [117]);
    expect(peaks.where((p) => p >= 300 && p < 320).length, 1);
    expect(
      peaks,
      everyElement(
        anyOf(inInclusiveRange(100, 129), inInclusiveRange(300, 319)),
      ),
    );
  });

  test('a chapter is described by its rank in its own book', () {
    final c = PaceCurve([for (var i = 0; i < 100; i++) i.toDouble(), null]);
    expect(c.describe(95), '全书最激烈的一成');
    expect(c.describe(75), '较激烈');
    expect(c.describe(50), '中等');
    expect(c.describe(5), '平缓');
    expect(c.describe(100), '篇幅太短，未计算');
  });

  test('scaling clamps to the chosen bounds and survives a flat book', () {
    expect(PaceCurve.scale([0.0, 5.0, 10.0, null], (0.0, 5.0)), [
      0.0,
      1.0,
      1.0,
      null,
    ]);
    expect(PaceCurve.scale([2.0, 2.0], PaceCurve.bounds([2.0, 2.0])), [
      0.5,
      0.5,
    ]);
  });
}
