enum ReaderTapAction { previousPage, toggleControls, nextPage, none }

/// Phone paging keeps a quiet central zone for showing and hiding controls.
/// Desktop retains the original half-page click targets.
ReaderTapAction resolveReaderTap({
  required double x,
  required double width,
  required bool compact,
  required bool annotationMode,
}) {
  if (annotationMode || width <= 0) return ReaderTapAction.none;
  final ratio = (x / width).clamp(0.0, 1.0);
  if (!compact) {
    return ratio < 0.5
        ? ReaderTapAction.previousPage
        : ReaderTapAction.nextPage;
  }
  if (ratio < 0.28) return ReaderTapAction.previousPage;
  if (ratio > 0.72) return ReaderTapAction.nextPage;
  return ReaderTapAction.toggleControls;
}
