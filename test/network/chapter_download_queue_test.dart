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
}
