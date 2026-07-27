import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/network/download.dart';

void main() {
  test('concurrent save requests keep the latest task snapshot', () async {
    final directory = await Directory.systemTemp.createTemp(
      'venera-download-task-test-',
    );
    final manager = LocalManager();
    final task = _TestDownloadTask();

    try {
      App.dataPath = directory.path;
      manager.downloadingTasks = [task];

      task.version = 1;
      final firstSave = manager.saveCurrentDownloadingTasks();
      task.version = 2;
      final secondSave = manager.saveCurrentDownloadingTasks();

      await Future.wait([firstSave, secondSave]);

      final data =
          jsonDecode(
                await File(
                  '${directory.path}/downloading_tasks.json',
                ).readAsString(),
              )
              as List<dynamic>;
      expect((data.single as Map<String, dynamic>)['version'], 2);
    } finally {
      manager.downloadingTasks = [];
      App.dataPath = directory.parent.path;
      await directory.delete(recursive: true);
    }
  });
}

class _TestDownloadTask extends DownloadTask {
  int version = 0;

  @override
  String? cover;

  @override
  ComicType get comicType => ComicType(0);

  @override
  String get id => 'test';

  @override
  bool get isError => false;

  @override
  bool get isPaused => true;

  @override
  String get message => '';

  @override
  double get progress => 0;

  @override
  int get speed => 0;

  @override
  String get title => 'Test';

  @override
  void cancel() {}

  @override
  void pause() {}

  @override
  void resume() {}

  @override
  Map<String, dynamic> toJson() => {'version': version};

  @override
  LocalComic toLocalComic() => throw UnsupportedError('Not used by this test');
}
