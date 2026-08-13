import 'package:flutter_test/flutter_test.dart';
import 'package:novel/reader_interaction.dart';

void main() {
  test('compact page has back, controls and forward tap zones', () {
    ReaderTapAction action(double x) => resolveReaderTap(
      x: x,
      width: 400,
      compact: true,
      annotationMode: false,
    );

    expect(action(50), ReaderTapAction.previousPage);
    expect(action(200), ReaderTapAction.toggleControls);
    expect(action(350), ReaderTapAction.nextPage);
  });

  test('annotation mode disables page tap actions', () {
    expect(
      resolveReaderTap(x: 390, width: 400, compact: true, annotationMode: true),
      ReaderTapAction.none,
    );
  });

  test('expanded page keeps original two click zones', () {
    expect(
      resolveReaderTap(
        x: 200,
        width: 800,
        compact: false,
        annotationMode: false,
      ),
      ReaderTapAction.previousPage,
    );
    expect(
      resolveReaderTap(
        x: 600,
        width: 800,
        compact: false,
        annotationMode: false,
      ),
      ReaderTapAction.nextPage,
    );
  });
}
