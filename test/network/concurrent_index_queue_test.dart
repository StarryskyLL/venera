import 'package:flutter_test/flutter_test.dart';
import 'package:venera/network/concurrent_index_queue.dart';

void main() {
  test('keeps the configured number of image lanes active', () {
    final queue = ConcurrentIndexQueue(
      start: 0,
      endExclusive: 5,
      concurrency: 2,
    );

    expect(queue.takeNext()!.index, 0);
    expect(queue.takeNext()!.index, 1);
    expect(queue.takeNext(), isNull);

    queue.complete(1);
    final next = queue.takeNext()!;
    expect(next.index, 2);
    expect(next.lane, 1);
  });

  test('only advances resumable progress through contiguous images', () {
    final queue = ConcurrentIndexQueue(
      start: 0,
      endExclusive: 3,
      concurrency: 3,
    );
    queue.takeNext();
    queue.takeNext();
    queue.takeNext();

    expect(queue.complete(2).advanced, 0);
    expect(queue.complete(1).advanced, 0);
    final completion = queue.complete(0);

    expect(completion.advanced, 3);
    expect(completion.committedThrough, 3);
    expect(queue.isDone, isTrue);
  });

  test('resumes from the persisted image index', () {
    final queue = ConcurrentIndexQueue(
      start: 4,
      endExclusive: 7,
      concurrency: 2,
    );

    expect(queue.takeNext()!.index, 4);
    expect(queue.takeNext()!.index, 5);
    expect(queue.complete(4).committedThrough, 5);
    expect(queue.takeNext()!.index, 6);
  });
}
