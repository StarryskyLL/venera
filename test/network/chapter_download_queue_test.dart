import 'package:flutter_test/flutter_test.dart';
import 'package:venera/network/chapter_download_queue.dart';

void main() {
  test('takes each unfinished chapter once in source order', () {
    final completed = {'chapter-2'};
    final queue = ChapterDownloadQueue([
      'chapter-1',
      'chapter-2',
      'chapter-3',
    ], completed);

    expect(queue.pendingCount, 2);
    expect(queue.takeNext(), 'chapter-1');
    expect(queue.takeNext(), 'chapter-3');
    expect(queue.takeNext(), isNull);
  });

  test('observes chapters completed while workers are running', () {
    final completed = <String>{};
    final queue = ChapterDownloadQueue(['chapter-1', 'chapter-2'], completed);

    expect(queue.takeNext(), 'chapter-1');
    completed.add('chapter-2');
    expect(queue.takeNext(), isNull);
  });

  test('feeds concurrent workers without assigning duplicates', () async {
    final chapters = List.generate(12, (index) => 'chapter-$index');
    final queue = ChapterDownloadQueue(chapters, <String>{});
    final assigned = <String>{};
    var activeWorkers = 0;
    var maxActiveWorkers = 0;

    Future<void> worker() async {
      while (true) {
        final chapter = queue.takeNext();
        if (chapter == null) return;
        activeWorkers++;
        if (activeWorkers > maxActiveWorkers) {
          maxActiveWorkers = activeWorkers;
        }
        await Future<void>.delayed(Duration.zero);
        expect(assigned.add(chapter), isTrue);
        activeWorkers--;
      }
    }

    await Future.wait(List.generate(5, (_) => worker()));

    expect(assigned, chapters.toSet());
    expect(maxActiveWorkers, 5);
  });

  test('paused active chapter releases its worker to the next chapter', () {
    final paused = <String>{};
    final queue = ChapterDownloadQueue(
      ['chapter-1', 'chapter-2'],
      <String>{},
      paused: paused,
    );

    expect(queue.takeNext(), 'chapter-1');
    queue.pause('chapter-1');
    queue.release('chapter-1');

    expect(paused, contains('chapter-1'));
    expect(queue.takeNext(), 'chapter-2');
  });

  test('resumed chapter is placed before chapters in source order', () {
    final queue = ChapterDownloadQueue(
      ['chapter-1', 'chapter-2', 'chapter-3'],
      <String>{},
      paused: {'chapter-1'},
    );

    expect(queue.takeNext(), 'chapter-2');
    queue.resume('chapter-1');

    expect(queue.takeNext(), 'chapter-1');
  });

  test('rapid resume does not duplicate a chapter still owned by a worker', () {
    final queue = ChapterDownloadQueue(
      ['chapter-1', 'chapter-2', 'chapter-3'],
      <String>{},
      paused: <String>{},
    );

    expect(queue.takeNext(), 'chapter-1');
    queue.pause('chapter-1');
    queue.resume('chapter-1');

    expect(queue.takeNext(), 'chapter-2');
    queue.release('chapter-1');
    expect(queue.takeNext(), 'chapter-1');
  });

  test('waiting workers wake when a paused chapter is resumed', () async {
    final queue = ChapterDownloadQueue(
      ['chapter-1'],
      <String>{},
      paused: {'chapter-1'},
    );

    final next = queue.waitNext();
    await Future<void>.delayed(Duration.zero);
    queue.resume('chapter-1');

    expect(await next, 'chapter-1');
  });

  test(
    'closing the queue releases workers waiting on paused chapters',
    () async {
      final queue = ChapterDownloadQueue(
        ['chapter-1'],
        <String>{},
        paused: {'chapter-1'},
      );

      final next = queue.waitNext();
      await Future<void>.delayed(Duration.zero);
      queue.close();

      expect(await next, isNull);
    },
  );
}
