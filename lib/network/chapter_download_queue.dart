import 'dart:async';
import 'dart:collection';

class ChapterDownloadQueue {
  ChapterDownloadQueue(
    Iterable<String> chapters,
    Set<String> completed, {
    Set<String>? paused,
    Iterable<String> priority = const [],
  }) : _chapters = List<String>.from(chapters),
       _completed = completed,
       _paused = paused ?? <String>{} {
    _chapterSet = _chapters.toSet();
    _countedCompleted = _chapterSet.where(_completed.contains).toSet();
    _remainingCount = _chapterSet.length - _countedCompleted.length;
    for (final chapter in List<String>.from(priority).reversed) {
      _addPriority(chapter);
    }
  }

  final List<String> _chapters;
  late final Set<String> _chapterSet;
  final Set<String> _completed;
  final Set<String> _paused;
  final Set<String> _active = {};
  late final Set<String> _countedCompleted;
  final Queue<String> _priority = Queue<String>();
  final Set<String> _prioritySet = {};

  int _nextIndex = 0;
  late int _remainingCount;
  Completer<void>? _availableCompleter;
  bool _isClosed = false;

  String? takeNext() {
    if (_isClosed || _isFinished) return null;

    final priorityCount = _priority.length;
    for (var i = 0; i < priorityCount; i++) {
      final chapter = _priority.removeFirst();
      if (_isChapterCompleted(chapter) || !_chapterSet.contains(chapter)) {
        _prioritySet.remove(chapter);
        continue;
      }
      if (_paused.contains(chapter) || _active.contains(chapter)) {
        _priority.addLast(chapter);
        continue;
      }
      _prioritySet.remove(chapter);
      _active.add(chapter);
      return chapter;
    }

    while (_nextIndex < _chapters.length) {
      final chapter = _chapters[_nextIndex++];
      if (_isChapterCompleted(chapter) ||
          _paused.contains(chapter) ||
          _active.contains(chapter)) {
        continue;
      }
      _active.add(chapter);
      return chapter;
    }
    return null;
  }

  Future<String?> waitNext() async {
    while (!_isClosed) {
      final chapter = takeNext();
      if (chapter != null) return chapter;
      if (_isFinished) return null;
      final completer = _availableCompleter ??= Completer<void>();
      await completer.future;
    }
    return null;
  }

  void pause(String chapter) {
    if (!_chapterSet.contains(chapter) || _isChapterCompleted(chapter)) return;
    _paused.add(chapter);
    _signalAvailability();
  }

  void resume(String chapter) {
    if (_isChapterCompleted(chapter) || !_chapterSet.contains(chapter)) return;
    _paused.remove(chapter);
    _addPriority(chapter);
    _signalAvailability();
  }

  void release(String chapter) {
    _active.remove(chapter);
    _isChapterCompleted(chapter);
    _signalAvailability();
  }

  void close() {
    if (_isClosed) return;
    _isClosed = true;
    _signalAvailability();
  }

  void _addPriority(String chapter) {
    if (_isChapterCompleted(chapter) ||
        !_chapterSet.contains(chapter) ||
        !_prioritySet.add(chapter)) {
      return;
    }
    _priority.addFirst(chapter);
  }

  void _signalAvailability() {
    final completer = _availableCompleter;
    _availableCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  bool _isChapterCompleted(String chapter) {
    if (!_chapterSet.contains(chapter)) return false;
    if (!_completed.contains(chapter)) return false;
    if (_countedCompleted.add(chapter)) {
      _remainingCount--;
    }
    return true;
  }

  bool get _isFinished => _remainingCount == 0;

  int get pendingCount => _remainingCount;
}
