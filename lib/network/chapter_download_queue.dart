class ChapterDownloadQueue {
  ChapterDownloadQueue(Iterable<String> chapters, Set<String> completed)
    : _chapters = List<String>.from(chapters),
      _completed = completed;

  final List<String> _chapters;
  final Set<String> _completed;

  int _nextIndex = 0;

  String? takeNext() {
    while (_nextIndex < _chapters.length) {
      final chapter = _chapters[_nextIndex++];
      if (!_completed.contains(chapter)) {
        return chapter;
      }
    }
    return null;
  }

  int get pendingCount =>
      _chapters.where((chapter) => !_completed.contains(chapter)).length;
}
