import 'dart:async';
import 'dart:isolate';

import 'package:flutter/widgets.dart' show ChangeNotifier;
import 'package:flutter_saf/flutter_saf.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/network/images.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/file_type.dart';
import 'package:venera/utils/io.dart';
import 'package:zip_flutter/zip_flutter.dart';

import 'chapter_download_queue.dart';
import 'concurrent_index_queue.dart';
import 'file_downloader.dart';

abstract class DownloadTask with ChangeNotifier {
  /// 0-1
  double get progress;

  bool get isError;

  bool get isPaused;

  /// bytes per second
  int get speed;

  void cancel();

  void pause();

  void resume();

  String get title;

  String? get cover;

  String get message;

  /// root path for the comic. If null, the task is not scheduled.
  String? path;

  /// convert current state to json, which can be used to restore the task
  Map<String, dynamic> toJson();

  LocalComic toLocalComic();

  String get id;

  ComicType get comicType;

  static DownloadTask? fromJson(Map<String, dynamic> json) {
    switch (json["type"]) {
      case "ImagesDownloadTask":
        return ImagesDownloadTask.fromJson(json);
      default:
        return null;
    }
  }

  @override
  bool operator ==(Object other) {
    return other is DownloadTask &&
        other.id == id &&
        other.comicType == comicType;
  }

  @override
  int get hashCode => Object.hash(id, comicType);
}

enum ChapterDownloadStatus {
  waiting,
  fetching,
  downloading,
  paused,
  completed,
  error,
}

class ChapterDownloadProgress {
  const ChapterDownloadProgress({
    required this.id,
    required this.title,
    required this.current,
    required this.total,
    required this.status,
    this.errorMessage,
  });

  final String id;
  final String title;
  final int current;
  final int total;
  final ChapterDownloadStatus status;
  final String? errorMessage;

  double get progress {
    if (status == ChapterDownloadStatus.completed) return 1;
    if (total == 0) return 0;
    return (current / total).clamp(0, 1).toDouble();
  }
}

class ImagesDownloadTask extends DownloadTask with _TransferSpeedMixin {
  final ComicSource source;

  final String comicId;

  /// comic details. If null, the comic details will be fetched from the source.
  ComicDetails? comic;

  /// chapters to download. If null, all chapters will be downloaded.
  final List<String>? chapters;

  @override
  String get id => comicId;

  @override
  ComicType get comicType => ComicType(source.key.hashCode);

  String? comicTitle;

  ImagesDownloadTask({
    required this.source,
    required this.comicId,
    this.comic,
    this.chapters,
    this.comicTitle,
  });

  @override
  void cancel() {
    _isRunning = false;
    _runId++;
    _progressNotifyTimer?.cancel();
    _progressNotifyTimer = null;
    _progressSaveTimer?.cancel();
    _progressSaveTimer = null;
    LocalManager().removeTask(this);
    var local = LocalManager().find(id, comicType);
    if (path != null) {
      if (local == null) {
        Future.sync(() async {
          var tasks = this.tasks.values.toList();
          for (var i = 0; i < tasks.length; i++) {
            if (!tasks[i].isComplete) {
              tasks[i].cancel();
              await tasks[i].wait();
            }
          }
          try {
            await Directory(path!).delete(recursive: true);
          } catch (e) {
            Log.error("Download", "Failed to delete directory: $e");
          }
        });
      } else if (chapters != null) {
        for (var c in chapters!) {
          var dir = Directory(FilePath.join(path!, c));
          if (dir.existsSync()) {
            dir.deleteSync(recursive: true);
          }
        }
      }
    }
  }

  @override
  String? get cover => _cover ?? comic?.cover;

  @override
  String get message => _message;

  @override
  void pause() {
    if (isPaused) {
      return;
    }
    _isRunning = false;
    _runId++;
    _message = "Paused";
    _currentSpeed = 0;
    _progressNotifyTimer?.cancel();
    _progressNotifyTimer = null;
    var shouldMove = <Object>[];
    for (var entry in tasks.entries) {
      if (!entry.value.isComplete) {
        entry.value.cancel();
        shouldMove.add(entry.key);
      }
    }
    for (var i in shouldMove) {
      tasks.remove(i);
    }
    stopRecorder();
    unawaited(_flushProgress());
    notifyListeners();
  }

  @override
  double get progress {
    if (comic?.chapters != null) {
      final chapterIds = _chapterIds;
      if (chapterIds.isEmpty) return 0;
      double completed = 0;
      for (final chapterId in chapterIds) {
        if (_completedChapters.contains(chapterId)) {
          completed++;
          continue;
        }
        final images = _images?[chapterId];
        if (images != null && images.isNotEmpty) {
          completed += (_chapterProgress[chapterId] ?? 0) / images.length;
        }
      }
      return (completed / chapterIds.length).clamp(0, 1).toDouble();
    }
    return _totalCount == 0 ? 0 : _downloadedCount / _totalCount;
  }

  bool _isRunning = false;

  bool _isError = false;

  String _message = "Fetching comic info...";

  String? _cover;

  /// All images to download, key is chapter name
  Map<String, List<String>>? _images;

  /// Downloaded image count
  int _downloadedCount = 0;

  /// Total image count
  int _totalCount = 0;

  /// Current downloading image index for comics without chapters.
  int _index = 0;

  /// Legacy chapter index, kept for restoring tasks saved by older versions.
  int _chapter = 0;

  Map<String, int> _chapterProgress = {};

  Set<String> _completedChapters = {};

  final Map<String, ChapterDownloadStatus> _chapterStates = {};

  final Map<String, String> _chapterErrors = {};

  var tasks = <Object, _ImageDownloadWrapper>{};

  int _runId = 0;

  Future<void>? _chapterWorkers;

  Timer? _progressSaveTimer;

  Timer? _progressNotifyTimer;

  static const _progressNotifyInterval = Duration(milliseconds: 50);

  List<String> get _chapterIds {
    final allChapters = comic?.chapters?.ids.toList() ?? const <String>[];
    if (chapters == null) return allChapters;
    final selected = chapters!.toSet();
    return allChapters.where(selected.contains).toList();
  }

  int get _maxConcurrentTasks {
    final value = (appdata.settings["downloadThreads"] as num).toInt();
    return value < 1 ? 1 : value;
  }

  int get _maxConcurrentImagesPerChapter {
    final value = (appdata.settings["chapterDownloadThreads"] as num).toInt();
    return value.clamp(1, 10).toInt();
  }

  bool _isCurrentRun(int runId) => _isRunning && _runId == runId;

  bool get hasChapterProgress => comic?.chapters != null;

  List<ChapterDownloadProgress> get chapterDownloadProgress {
    if (!hasChapterProgress) return const [];
    return _chapterIds
        .map((chapterId) {
          final images = _images?[chapterId];
          final total = images?.length ?? 0;
          final current = (_chapterProgress[chapterId] ?? 0)
              .clamp(0, total)
              .toInt();
          return ChapterDownloadProgress(
            id: chapterId,
            title: comic!.chapters![chapterId] ?? chapterId,
            current: current,
            total: total,
            status: _chapterStatus(chapterId),
            errorMessage: _chapterErrors[chapterId],
          );
        })
        .toList(growable: false);
  }

  ChapterDownloadStatus _chapterStatus(String chapterId) {
    if (_completedChapters.contains(chapterId)) {
      return ChapterDownloadStatus.completed;
    }
    if (_chapterErrors.containsKey(chapterId)) {
      return ChapterDownloadStatus.error;
    }
    if (!_isRunning) {
      return ChapterDownloadStatus.paused;
    }
    return _chapterStates[chapterId] ?? ChapterDownloadStatus.waiting;
  }

  void _scheduleProgressSave() {
    _progressSaveTimer ??= Timer(const Duration(seconds: 5), () {
      _progressSaveTimer = null;
      unawaited(LocalManager().saveCurrentDownloadingTasks());
    });
  }

  Future<void> _flushProgress() {
    _progressSaveTimer?.cancel();
    _progressSaveTimer = null;
    return LocalManager().saveCurrentDownloadingTasks();
  }

  void _notifyProgressChanged() {
    if (_progressNotifyTimer != null) return;
    _progressNotifyTimer = Timer(_progressNotifyInterval, () {
      _progressNotifyTimer = null;
      notifyListeners();
    });
  }

  void _scheduleSingleComicTasks(int runId) {
    var images = _images!['']!;
    var downloading = 0;
    for (var i = _index; i < images.length; i++) {
      if (downloading >= _maxConcurrentTasks) {
        return;
      }
      if (tasks[i] != null) {
        if (!tasks[i]!.isComplete) {
          downloading++;
        }
        if (tasks[i]!.error == null) {
          continue;
        }
      }
      final saveTo = Directory(path!);
      var task = _ImageDownloadWrapper(this, '', images[i], saveTo, i);
      tasks[i] = task;
      task.wait().then((task) {
        if (task.isComplete && _isCurrentRun(runId)) {
          _scheduleSingleComicTasks(runId);
        }
      });
      downloading++;
    }
  }

  Future<bool> _downloadSingleComic(int runId) async {
    var images = _images!['']!;
    tasks.clear();
    while (_index < images.length) {
      _scheduleSingleComicTasks(runId);
      var task = tasks[_index]!;
      await task.wait();
      if (!_isCurrentRun(runId)) {
        return false;
      }
      if (task.error != null) {
        throw task.error!;
      }
      _index++;
      _downloadedCount++;
      _message = "$_downloadedCount/$_totalCount";
      _scheduleProgressSave();
      _notifyProgressChanged();
    }
    await LocalManager().markChapterDownloaded(
      comicId,
      ComicType(source.key.hashCode),
      '',
      comicBuilder: toLocalComic,
    );
    return true;
  }

  Future<bool> _downloadChapteredComic(int runId) async {
    final previousWorkers = _chapterWorkers;
    if (previousWorkers != null) {
      await previousWorkers;
      if (!_isCurrentRun(runId)) return false;
    }

    _images ??= {};
    final queue = ChapterDownloadQueue(_chapterIds, _completedChapters);
    final pendingCount = queue.pendingCount;
    if (pendingCount == 0) return true;

    final workerCount = pendingCount < _maxConcurrentTasks
        ? pendingCount
        : _maxConcurrentTasks;
    final Future<void> workers = Future.wait(
      List.generate(
        workerCount,
        (workerIndex) => _chapterWorker(queue, runId, workerIndex),
      ),
    ).then((_) {});
    _chapterWorkers = workers;
    await workers;
    if (identical(_chapterWorkers, workers)) {
      _chapterWorkers = null;
    }
    return _isCurrentRun(runId) &&
        _chapterIds.every(_completedChapters.contains);
  }

  Future<void> _chapterWorker(
    ChapterDownloadQueue queue,
    int runId,
    int workerIndex,
  ) async {
    while (_isCurrentRun(runId)) {
      final chapterId = queue.takeNext();
      if (chapterId == null) return;
      try {
        await _downloadChapter(chapterId, runId, workerIndex);
      } catch (e, s) {
        if (_isCurrentRun(runId)) {
          _chapterStates[chapterId] = ChapterDownloadStatus.error;
          _chapterErrors[chapterId] = e.toString();
          Log.error("Download", e.toString(), s);
          _setError("Error: $e");
        }
        return;
      }
    }
  }

  Future<void> _downloadChapter(
    String chapterId,
    int runId,
    int workerIndex,
  ) async {
    var images = _images![chapterId];
    _chapterErrors.remove(chapterId);
    _chapterStates[chapterId] = images == null
        ? ChapterDownloadStatus.fetching
        : ChapterDownloadStatus.downloading;
    notifyListeners();
    if (images == null) {
      final fetchedCount = _chapterIds.where(_images!.containsKey).length;
      _message = "Fetching image list ($fetchedCount/${_chapterIds.length})...";
      notifyListeners();
      final res = await _runWithRetry(() async {
        final result = await source.loadComicPages!(comicId, chapterId);
        if (result.error) {
          throw result.errorMessage!;
        }
        return result.data;
      });
      if (!_isCurrentRun(runId)) return;
      if (res.error) {
        throw res.errorMessage!;
      }
      images = res.data;
      _images![chapterId] = images;
      _totalCount += images.length;
      _chapterStates[chapterId] = ChapterDownloadStatus.downloading;
      _scheduleProgressSave();
      notifyListeners();
      if (!_isCurrentRun(runId)) return;
    }

    final saveTo = Directory(
      FilePath.join(path!, LocalManager.getChapterDirectoryName(chapterId)),
    );
    if (!saveTo.existsSync()) {
      saveTo.createSync(recursive: true);
    }

    final startIndex = (_chapterProgress[chapterId] ?? 0)
        .clamp(0, images.length)
        .toInt();
    final queue = ConcurrentIndexQueue(
      start: startIndex,
      endExclusive: images.length,
      concurrency: _maxConcurrentImagesPerChapter,
    );
    final active = <int, Future<_ImageDownloadWrapper>>{};

    void scheduleImages() {
      ConcurrentIndexSlot? slot;
      while ((slot = queue.takeNext()) != null) {
        final currentSlot = slot!;
        final task = _ImageDownloadWrapper(
          this,
          chapterId,
          images![currentSlot.index],
          saveTo,
          currentSlot.index,
          connectionPoolKey:
              'download-worker-$workerIndex-image-${currentSlot.lane}',
        );
        active[currentSlot.index] = task.wait();
        tasks[(chapterId, currentSlot.index)] = task;
      }
    }

    scheduleImages();
    while (active.isNotEmpty) {
      final task = await Future.any(active.values);
      active.remove(task.index);
      final taskKey = (chapterId, task.index);
      if (identical(tasks[taskKey], task)) {
        tasks.remove(taskKey);
      }
      if (!_isCurrentRun(runId)) return;
      if (task.error != null) {
        throw task.error!;
      }
      final completion = queue.complete(task.index);
      if (completion.advanced > 0) {
        _chapterProgress[chapterId] = completion.committedThrough;
        _downloadedCount += completion.advanced;
        _message = "$_downloadedCount/$_totalCount";
        _scheduleProgressSave();
        _notifyProgressChanged();
      }
      scheduleImages();
    }

    _chapterProgress[chapterId] = images.length;
    await LocalManager().markChapterDownloaded(
      comicId,
      ComicType(source.key.hashCode),
      chapterId,
      comicBuilder: toLocalComic,
    );
    _completedChapters.add(chapterId);
    _chapterStates[chapterId] = ChapterDownloadStatus.completed;
    notifyListeners();
    await _flushProgress();
  }

  @override
  void resume() async {
    if (_isRunning) return;
    final runId = ++_runId;
    _isError = false;
    _chapterErrors.clear();
    _message = "Resuming...";
    _isRunning = true;
    notifyListeners();
    runRecorder();

    if (comic == null) {
      _message = "Fetching comic info...";
      notifyListeners();
      var res = await _runWithRetry(() async {
        var r = await source.loadComicInfo!(comicId);
        if (r.error) {
          throw r.errorMessage!;
        } else {
          return r.data;
        }
      });
      if (!_isCurrentRun(runId)) {
        return;
      }
      if (res.error) {
        _setError("Error: ${res.errorMessage}");
        return;
      } else {
        comic = res.data;
      }
    }

    if (path == null) {
      try {
        var dir = await LocalManager().findValidDirectory(
          comicId,
          comicType,
          comic!.title,
        );
        if (!(await dir.exists())) {
          await dir.create();
        }
        path = dir.path;
      } catch (e, s) {
        Log.error("Download", e.toString(), s);
        _setError("Error: $e");
        return;
      }
    }

    await _flushProgress();
    if (!_isCurrentRun(runId)) return;

    if (_cover == null) {
      _message = "Downloading cover...";
      notifyListeners();
      var res = await _runWithRetry(() async {
        Uint8List? data;
        await for (var progress in ImageDownloader.loadThumbnail(
          comic!.cover,
          source.key,
        )) {
          if (progress.imageBytes != null) {
            data = progress.imageBytes;
          }
        }
        if (data == null) {
          throw "Failed to download cover";
        }
        var fileType = detectFileType(data);
        var file = File(FilePath.join(path!, "cover${fileType.ext}"));
        file.writeAsBytesSync(data);
        return "file://${file.path}";
      });
      if (res.error) {
        Log.error("Download", res.errorMessage!);
        _setError("Error: ${res.errorMessage}");
        return;
      } else {
        _cover = res.data;
        notifyListeners();
      }
      await _flushProgress();
      if (!_isCurrentRun(runId)) return;
    }

    bool isComplete;
    try {
      if (comic!.chapters == null) {
        if (_images == null) {
          _message = "Fetching image list...";
          notifyListeners();
          var res = await _runWithRetry(() async {
            var r = await source.loadComicPages!(comicId, null);
            if (r.error) {
              throw r.errorMessage!;
            } else {
              return r.data;
            }
          });
          if (!_isCurrentRun(runId)) {
            return;
          }
          if (res.error) {
            Log.error("Download", res.errorMessage!);
            _setError("Error: ${res.errorMessage}");
            return;
          } else {
            _images = {'': res.data};
            _totalCount = _images!['']!.length;
          }
        }
        _message = "$_downloadedCount/$_totalCount";
        notifyListeners();
        await _flushProgress();
        if (!_isCurrentRun(runId)) return;
        isComplete = await _downloadSingleComic(runId);
      } else {
        isComplete = await _downloadChapteredComic(runId);
      }
    } catch (e, s) {
      if (_isCurrentRun(runId)) {
        Log.error("Download", e.toString(), s);
        _setError("Error: $e");
      }
      return;
    }

    if (!isComplete || !_isCurrentRun(runId)) return;
    _isRunning = false;
    _progressNotifyTimer?.cancel();
    _progressNotifyTimer = null;
    _progressSaveTimer?.cancel();
    _progressSaveTimer = null;
    LocalManager().completeTask(this);
    stopRecorder();
  }

  @override
  void onNextSecond(Timer t) {
    super.onNextSecond(t);
    notifyListeners();
  }

  void _setError(String message) {
    _isRunning = false;
    _runId++;
    _isError = true;
    _message = message;
    _progressNotifyTimer?.cancel();
    _progressNotifyTimer = null;
    for (final task in tasks.values) {
      if (!task.isComplete) {
        task.cancel();
      }
    }
    tasks.clear();
    unawaited(_flushProgress());
    notifyListeners();
    stopRecorder();
  }

  @override
  int get speed => currentSpeed;

  @override
  String get title => comic?.title ?? comicTitle ?? "Loading...";

  @override
  Map<String, dynamic> toJson() {
    return {
      "type": "ImagesDownloadTask",
      "source": source.key,
      "comicId": comicId,
      "comic": comic?.toJson(),
      "chapters": chapters,
      "path": path,
      "cover": _cover,
      "images": _images,
      "downloadedCount": _downloadedCount,
      "totalCount": _totalCount,
      "index": _index,
      "chapter": _chapter,
      "chapterProgress": _chapterProgress,
      "completedChapters": _completedChapters.toList(),
    };
  }

  static ImagesDownloadTask? fromJson(Map<String, dynamic> json) {
    if (json["type"] != "ImagesDownloadTask") {
      return null;
    }

    Map<String, List<String>>? images;
    if (json["images"] != null) {
      images = {};
      for (var entry in json["images"].entries) {
        images[entry.key] = List<String>.from(entry.value);
      }
    }

    final task =
        ImagesDownloadTask(
            source: ComicSource.find(json["source"])!,
            comicId: json["comicId"],
            comic: json["comic"] == null
                ? null
                : ComicDetails.fromJson(json["comic"]),
            chapters: ListOrNull.from(json["chapters"]),
          )
          ..path = json["path"]
          .._cover = json["cover"]
          .._images = images
          .._downloadedCount = (json["downloadedCount"] as num?)?.toInt() ?? 0
          .._totalCount = (json["totalCount"] as num?)?.toInt() ?? 0
          .._index = (json["index"] as num?)?.toInt() ?? 0
          .._chapter = (json["chapter"] as num?)?.toInt() ?? 0;

    final rawProgress = json["chapterProgress"];
    if (rawProgress is Map) {
      task._chapterProgress = {
        for (final entry in rawProgress.entries)
          if (entry.key is String && entry.value is num)
            entry.key as String: (entry.value as num).toInt(),
      };
    }
    task._completedChapters = Set<String>.from(
      json["completedChapters"] as List? ?? const [],
    );
    task._restoreLegacyChapterProgress(json);
    return task;
  }

  void _restoreLegacyChapterProgress(Map<String, dynamic> json) {
    if (comic?.chapters == null ||
        _images == null ||
        json["chapterProgress"] != null) {
      return;
    }
    final chapterIds = _images!.keys.toList();
    final completedCount = _chapter.clamp(0, chapterIds.length).toInt();
    for (var i = 0; i < completedCount; i++) {
      final chapterId = chapterIds[i];
      _completedChapters.add(chapterId);
      _chapterProgress[chapterId] = _images![chapterId]!.length;
    }
    if (completedCount < chapterIds.length) {
      final chapterId = chapterIds[completedCount];
      _chapterProgress[chapterId] = _index
          .clamp(0, _images![chapterId]!.length)
          .toInt();
    }
  }

  @override
  bool get isError => _isError;

  @override
  bool get isPaused => !_isRunning;

  @override
  LocalComic toLocalComic() {
    return LocalComic(
      id: comic!.id,
      title: title,
      subtitle: comic!.subTitle ?? '',
      tags: comic!.tags.entries.expand((e) {
        return e.value.map((v) => "${e.key}:$v");
      }).toList(),
      directory: Directory(path!).name,
      chapters: comic!.chapters,
      cover: File(_cover!.split("file://").last).name,
      comicType: ComicType(source.key.hashCode),
      downloadedChapters: chapters ?? comic?.chapters?.ids.toList() ?? [],
      createdAt: DateTime.now(),
    );
  }

  @override
  bool operator ==(Object other) {
    if (other is ImagesDownloadTask) {
      return other.comicId == comicId && other.source.key == source.key;
    }
    return false;
  }

  @override
  int get hashCode => Object.hash(comicId, source.key);
}

Future<Res<T>> _runWithRetry<T>(
  Future<T> Function() task, {
  int retry = 3,
}) async {
  for (var i = 0; i < retry; i++) {
    try {
      return Res(await task());
    } catch (e) {
      if (i == retry - 1) {
        return Res.error(e.toString());
      }
      await Future.delayed(Duration(seconds: i + 1));
    }
  }
  throw UnimplementedError();
}

class _ImageDownloadWrapper {
  final ImagesDownloadTask task;

  final String chapter;

  final int index;

  final String image;

  final Directory saveTo;

  final String? connectionPoolKey;

  _ImageDownloadWrapper(
    this.task,
    this.chapter,
    this.image,
    this.saveTo,
    this.index, {
    this.connectionPoolKey,
  }) {
    start();
  }

  bool isComplete = false;

  String? error;

  bool isCancelled = false;

  void cancel() {
    isCancelled = true;
    _completeWaiters();
  }

  var completers = <Completer<_ImageDownloadWrapper>>[];

  var retry = 3;

  void start() async {
    int lastBytes = 0;
    try {
      await for (var p in ImageDownloader.loadComicImageUnwrapped(
        image,
        task.source.key,
        task.comicId,
        chapter,
        cacheResult: false,
        readCache: false,
        connectionPoolKey: connectionPoolKey,
        savePathWithoutExtension: FilePath.join(saveTo.path, index.toString()),
      )) {
        if (isCancelled) {
          return;
        }
        task.onData(p.currentBytes - lastBytes);
        lastBytes = p.currentBytes;
      }
      if (isCancelled) return;
      isComplete = true;
      _completeWaiters();
    } catch (e, s) {
      if (isCancelled) {
        return;
      }
      Log.error("Download", e.toString(), s);
      retry--;
      if (retry > 0) {
        start();
        return;
      }
      error = e.toString();
      _completeWaiters();
    }
  }

  void _completeWaiters() {
    for (var c in completers) {
      if (!c.isCompleted) {
        c.complete(this);
      }
    }
    completers.clear();
  }

  Future<_ImageDownloadWrapper> wait() {
    if (isComplete || isCancelled || error != null) {
      return Future.value(this);
    }
    var c = Completer<_ImageDownloadWrapper>();
    completers.add(c);
    return c.future;
  }
}

abstract mixin class _TransferSpeedMixin {
  int _bytesSinceLastSecond = 0;

  int _currentSpeed = 0;

  int get currentSpeed => _currentSpeed;

  Timer? timer;

  void onData(int length) {
    if (timer == null) return;
    if (length < 0) {
      return;
    }
    _bytesSinceLastSecond += length;
  }

  void onNextSecond(Timer t) {
    _currentSpeed = _bytesSinceLastSecond;
    _bytesSinceLastSecond = 0;
  }

  void runRecorder() {
    if (timer != null) {
      timer!.cancel();
    }
    _bytesSinceLastSecond = 0;
    timer = Timer.periodic(const Duration(seconds: 1), onNextSecond);
  }

  void stopRecorder() {
    timer?.cancel();
    timer = null;
    _currentSpeed = 0;
    _bytesSinceLastSecond = 0;
  }
}

class ArchiveDownloadTask extends DownloadTask {
  final String archiveUrl;

  final ComicDetails comic;

  late ComicSource source;

  /// Download comic by archive url
  ///
  /// Currently only support zip file and comics without chapters
  ArchiveDownloadTask(this.archiveUrl, this.comic) {
    source = ComicSource.find(comic.sourceKey)!;
  }

  FileDownloader? _downloader;

  String _message = "Fetching comic info...";

  bool _isRunning = false;

  bool _isError = false;

  void _setError(String message) {
    _isRunning = false;
    _isError = true;
    _message = message;
    notifyListeners();
    Log.error("Download", message);
  }

  @override
  void cancel() async {
    _isRunning = false;
    await _downloader?.stop();
    if (path != null) {
      Directory(path!).deleteIgnoreError(recursive: true);
    }
    path = null;
    LocalManager().removeTask(this);
  }

  @override
  ComicType get comicType => ComicType(source.key.hashCode);

  @override
  String? get cover => comic.cover;

  @override
  String get id => comic.id;

  @override
  bool get isError => _isError;

  @override
  bool get isPaused => !_isRunning;

  @override
  String get message => _message;

  int _currentBytes = 0;

  int _expectedBytes = 0;

  int _speed = 0;

  @override
  void pause() {
    _isRunning = false;
    _message = "Paused";
    _downloader?.stop();
    notifyListeners();
  }

  @override
  double get progress =>
      _expectedBytes == 0 ? 0 : _currentBytes / _expectedBytes;

  @override
  void resume() async {
    if (_isRunning) {
      return;
    }
    _isError = false;
    _isRunning = true;
    notifyListeners();
    _message = "Downloading...";

    if (path == null) {
      var dir = await LocalManager().findValidDirectory(
        comic.id,
        comicType,
        comic.title,
      );
      if (!(await dir.exists())) {
        try {
          await dir.create();
        } catch (e) {
          _setError("Error: $e");
          return;
        }
      }
      path = dir.path;
    }

    var archiveFile = File(
      FilePath.join(App.dataPath, "archive_downloading.zip"),
    );

    Log.info("Download", "Downloading $archiveUrl");

    _downloader = FileDownloader(archiveUrl, archiveFile.path);

    bool isDownloaded = false;

    try {
      await for (var status in _downloader!.start()) {
        _currentBytes = status.downloadedBytes;
        _expectedBytes = status.totalBytes;
        _message =
            "${bytesToReadableString(_currentBytes)}/${bytesToReadableString(_expectedBytes)}";
        _speed = status.bytesPerSecond;
        isDownloaded = status.isFinished;
        notifyListeners();
      }
    } catch (e) {
      _setError("Error: $e");
      return;
    }

    if (!_isRunning) {
      return;
    }

    if (!isDownloaded) {
      _setError("Error: Download failed");
      return;
    }

    try {
      await _extractArchive(archiveFile.path, path!);
    } catch (e) {
      _setError("Failed to extract archive: $e");
      return;
    }

    await archiveFile.deleteIgnoreError();

    LocalManager().completeTask(this);
  }

  static Future<void> _extractArchive(String archive, String outDir) async {
    var out = Directory(outDir);
    if (out is AndroidDirectory) {
      // Saf directory can't be accessed by native code.
      var cacheDir = FilePath.join(App.cachePath, "archive_downloading");
      Directory(cacheDir).forceCreateSync();
      await Isolate.run(() {
        ZipFile.openAndExtract(archive, cacheDir);
      });
      await copyDirectoryIsolate(Directory(cacheDir), Directory(outDir));
      await Directory(cacheDir).deleteIgnoreError(recursive: true);
    } else {
      await Isolate.run(() {
        ZipFile.openAndExtract(archive, outDir);
      });
    }
  }

  @override
  int get speed => _speed;

  @override
  String get title => comic.title;

  @override
  Map<String, dynamic> toJson() {
    return {
      "type": "ArchiveDownloadTask",
      "archiveUrl": archiveUrl,
      "comic": comic.toJson(),
      "path": path,
    };
  }

  static ArchiveDownloadTask? fromJson(Map<String, dynamic> json) {
    if (json["type"] != "ArchiveDownloadTask") {
      return null;
    }
    return ArchiveDownloadTask(
      json["archiveUrl"],
      ComicDetails.fromJson(json["comic"]),
    )..path = json["path"];
  }

  String _findCover() {
    var files = Directory(path!).listSync();
    for (var f in files) {
      if (f.name.startsWith('cover')) {
        return f.name;
      }
    }
    files.sort((a, b) {
      return a.name.compareTo(b.name);
    });
    return files.first.name;
  }

  @override
  LocalComic toLocalComic() {
    return LocalComic(
      id: comic.id,
      title: title,
      subtitle: comic.subTitle ?? '',
      tags: comic.tags.entries.expand((e) {
        return e.value.map((v) => "${e.key}:$v");
      }).toList(),
      directory: Directory(path!).name,
      chapters: null,
      cover: _findCover(),
      comicType: ComicType(source.key.hashCode),
      downloadedChapters: [],
      createdAt: DateTime.now(),
    );
  }
}
