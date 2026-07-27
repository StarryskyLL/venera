import 'package:flutter_test/flutter_test.dart';
import 'package:venera/network/download.dart';

void main() {
  test('chapter progress reports the downloaded image ratio', () {
    const progress = ChapterDownloadProgress(
      id: 'chapter-1',
      title: 'Chapter 1',
      current: 25,
      total: 100,
      status: ChapterDownloadStatus.downloading,
    );

    expect(progress.progress, 0.25);
  });

  test('completed chapter reports full progress without an image count', () {
    const progress = ChapterDownloadProgress(
      id: 'chapter-1',
      title: 'Chapter 1',
      current: 0,
      total: 0,
      status: ChapterDownloadStatus.completed,
    );

    expect(progress.progress, 1);
  });
}
