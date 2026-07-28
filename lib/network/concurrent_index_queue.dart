import 'dart:collection';

class ConcurrentIndexSlot {
  const ConcurrentIndexSlot(this.index, this.lane);

  final int index;
  final int lane;
}

class ConcurrentIndexCompletion {
  const ConcurrentIndexCompletion({
    required this.committedThrough,
    required this.advanced,
  });

  final int committedThrough;
  final int advanced;
}

class ConcurrentIndexQueue {
  ConcurrentIndexQueue({
    required int start,
    required this.endExclusive,
    required int concurrency,
  }) : _nextIndex = start,
       _committedThrough = start,
       _availableLanes = Queue<int>.of(
         List<int>.generate(
           concurrency < 1 ? 1 : concurrency,
           (index) => index,
         ),
       );

  final int endExclusive;
  final Queue<int> _availableLanes;
  final Map<int, int> _activeLanes = {};
  final Set<int> _completed = {};

  int _nextIndex;
  int _committedThrough;

  ConcurrentIndexSlot? takeNext() {
    if (_nextIndex >= endExclusive || _availableLanes.isEmpty) {
      return null;
    }
    final index = _nextIndex++;
    final lane = _availableLanes.removeFirst();
    _activeLanes[index] = lane;
    return ConcurrentIndexSlot(index, lane);
  }

  ConcurrentIndexCompletion complete(int index) {
    final lane = _activeLanes.remove(index);
    if (lane == null) {
      throw StateError('Index $index is not active');
    }
    _availableLanes.addLast(lane);
    _completed.add(index);

    var advanced = 0;
    while (_completed.remove(_committedThrough)) {
      _committedThrough++;
      advanced++;
    }
    return ConcurrentIndexCompletion(
      committedThrough: _committedThrough,
      advanced: advanced,
    );
  }

  bool get isDone => _committedThrough >= endExclusive && _activeLanes.isEmpty;
}
