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

  test('nearbyWindow returns up to 5 chapters around anchor', () {
    final c = PaceCurve([for (var i = 0; i < 20; i++) i.toDouble()]);
    expect(c.nearbyWindow(0), [0, 1, 2, 3, 4]);
    expect(c.nearbyWindow(5), [4, 5, 6, 7, 8]);
    expect(c.nearbyWindow(19), [15, 16, 17, 18, 19]);
  });

  test('trendHint detects high-tension, rising, and calm stretches', () {
    final c = PaceCurve([
      0.0,
      0.1,
      0.2,
      0.1,
      0.2,
      0.3,
      2.5,
      3.0,
      0.2,
      0.1,
    ]);
    expect(c.trendHint(0), '当前处于平缓铺垫段');
    expect(c.trendHint(4), '接下来节奏升温');
    expect(c.trendHint(7), '当前正处高能段');
  });
}
