import 'dart:async';
import 'dart:collection';
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

import 'file_downloader.dart';

class DownloadChapterProgress {
  const DownloadChapterProgress({
    required this.id,
    required this.title,
    required this.downloaded,
    required this.total,
    required this.isCompleted,
    required this.isRunning,
    required this.hasImageList,
  });

  final String id;

  final String title;

  final int downloaded;

  final int? total;

  final bool isCompleted;

  final bool isRunning;

  final bool hasImageList;

  double? get progress {
    var imageCount = total;
    if (imageCount == null) {
      return null;
    }
    if (imageCount == 0) {
      return isCompleted ? 1.0 : 0.0;
    }
    return downloaded.clamp(0, imageCount).toDouble() / imageCount;
  }
}

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

  List<DownloadChapterProgress> get chapterProgresses => const [];

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
    LocalManager().removeTask(this);
    var local = LocalManager().find(id, comicType);
    if (path != null) {
      if (local == null) {
        Future.sync(() async {
          var tasks = _activeDownloads();
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
          var dir = Directory(
            FilePath.join(path!, LocalManager.getChapterDirectoryName(c)),
          );
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
    _message = "Paused";
    _currentSpeed = 0;
    _cancelActiveDownloads();
    stopRecorder();
    notifyListeners();
  }

  @override
  double get progress {
    if (comic?.chapters != null) {
      var chapterIds = _downloadChapterIds;
      if (chapterIds.isEmpty) {
        return 0;
      }
      double completed = 0;
      for (var chapterId in chapterIds) {
        if (_completedChapters.contains(chapterId)) {
          completed++;
          continue;
        }
        var images = _images?[chapterId];
        if (images == null || images.isEmpty) {
          continue;
        }
        var downloaded =
            _chapterDownloadedIndexes[chapterId]?.length ??
            _chapterDownloadedCounts[chapterId] ??
            0;
        completed += (downloaded / images.length).clamp(0, 1).toDouble();
      }
      return completed / chapterIds.length;
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

  /// Current downloading image index
  int _index = 0;

  /// Current downloading chapter, index of [_images]
  int _chapter = 0;

  /// Downloaded image count of each chapter.
  final Map<String, int> _chapterDownloadedCounts = {};

  /// Downloaded image indexes of each chapter.
  final Map<String, Set<int>> _chapterDownloadedIndexes = {};

  /// Chapters that have finished downloading.
  final Set<String> _completedChapters = {};

  /// Chapters that are currently handled by chapter workers.
  final Set<String> _activeChapters = {};

  var tasks = <int, _ImageDownloadWrapper>{};

  final _chapterTasks = <String, Map<int, _ImageDownloadWrapper>>{};

  DateTime _lastDownloadingTaskSave = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> _downloadingTaskSave = Future.value();

  Completer<void>? _chapterDownloadWake;

  int _chapterDownloadWakeVersion = 0;

  int get _configuredDownloadThreads =>
      ((appdata.settings["downloadThreads"] as num?)?.toInt() ?? 5)
          .clamp(1, 32)
          .toInt();

  int get _maxConcurrentTasks => _configuredDownloadThreads;

  int get _maxConcurrentChapters => _configuredDownloadThreads;

  List<String> get _downloadChapterIds {
    var ids = comic?.chapters?.ids.toList() ?? <String>[];
    if (chapters == null) {
      return ids;
    }
    var selectedChapters = chapters!.toSet();
    return ids.where(selectedChapters.contains).toList();
  }

  @override
  List<DownloadChapterProgress> get chapterProgresses {
    var chapters = comic?.chapters;
    if (chapters == null) {
      return const [];
    }
    return [
      for (var chapterId in _downloadChapterIds)
        DownloadChapterProgress(
          id: chapterId,
          title: chapters[chapterId] ?? chapterId,
          downloaded: _completedChapters.contains(chapterId)
              ? (_images?[chapterId]?.length ??
                    _chapterDownloadedCounts[chapterId] ??
                    0)
              : (_chapterDownloadedIndexes[chapterId]?.length ??
                    _chapterDownloadedCounts[chapterId] ??
                    0),
          total: _images?[chapterId]?.length,
          isCompleted: _completedChapters.contains(chapterId),
          isRunning: _activeChapters.contains(chapterId),
          hasImageList: _images?[chapterId] != null,
        ),
    ];
  }

  String _chapterProgressMessage([List<String>? chapterIds]) {
    chapterIds ??= _downloadChapterIds;
    var completed = chapterIds.where(_completedChapters.contains).length;
    var downloading = _activeChapterImageDownloadCount;
    if (downloading == 0) {
      return "$completed/${chapterIds.length} chapters";
    }
    return "$completed/${chapterIds.length} chapters "
        "($downloading images downloading)";
  }

  Future<void> _saveCurrentDownloadingTasksState({bool force = false}) async {
    var now = DateTime.now();
    if (!force &&
        now.difference(_lastDownloadingTaskSave) < const Duration(seconds: 1)) {
      return;
    }
    _lastDownloadingTaskSave = now;
    var save = _downloadingTaskSave.then((_) {
      return LocalManager().saveCurrentDownloadingTasks();
    });
    _downloadingTaskSave = save.catchError((_) async {});
    await save;
  }

  List<_ImageDownloadWrapper> _activeDownloads() {
    return [
      ...tasks.values,
      for (var chapterTasks in _chapterTasks.values) ...chapterTasks.values,
    ];
  }

  int get _activeChapterImageDownloadCount {
    var count = 0;
    for (var chapterTasks in _chapterTasks.values) {
      count += chapterTasks.values.where((task) => !task.isComplete).length;
    }
    return count;
  }

  void _wakeChapterDownloadScheduler() {
    _chapterDownloadWakeVersion++;
    var wake = _chapterDownloadWake;
    if (wake != null && !wake.isCompleted) {
      wake.complete();
    }
  }

  void _cancelActiveDownloads() {
    for (var task in _activeDownloads()) {
      if (!task.isComplete) {
        task.cancel();
      }
    }
    tasks.clear();
    _chapterTasks.clear();
    _activeChapters.clear();
    _wakeChapterDownloadScheduler();
  }

  void _scheduleTasks() {
    var images = _images![_images!.keys.elementAt(_chapter)]!;
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
      Directory saveTo;
      if (comic!.chapters != null) {
        saveTo = Directory(
          FilePath.join(
            path!,
            LocalManager.getChapterDirectoryName(
              _images!.keys.elementAt(_chapter),
            ),
          ),
        );
        if (!saveTo.existsSync()) {
          saveTo.createSync(recursive: true);
        }
      } else {
        saveTo = Directory(path!);
      }
      var task = _ImageDownloadWrapper(
        this,
        _images!.keys.elementAt(_chapter),
        images[i],
        saveTo,
        i,
      );
      tasks[i] = task;
      task.wait().then((task) {
        if (task.isComplete) {
          _scheduleTasks();
        }
      });
      downloading++;
    }
  }

  void _migrateLegacyChapterProgress(List<String> chapterIds) {
    if (_chapterDownloadedIndexes.isNotEmpty) {
      return;
    }
    if (_images == null || chapterIds.isEmpty) {
      return;
    }
    var hasPerChapterProgress =
        _chapterDownloadedCounts.isNotEmpty || _completedChapters.isNotEmpty;
    for (var i = 0; i < chapterIds.length; i++) {
      var chapterId = chapterIds[i];
      var images = _images![chapterId];
      if (images == null) {
        continue;
      }
      var downloaded = 0;
      if (_completedChapters.contains(chapterId)) {
        downloaded = images.length;
      } else if (_chapterDownloadedCounts.containsKey(chapterId)) {
        downloaded = _chapterDownloadedCounts[chapterId]!
            .clamp(0, images.length)
            .toInt();
      } else if (!hasPerChapterProgress) {
        if (i < _chapter) {
          downloaded = images.length;
        } else if (i == _chapter) {
          downloaded = _index.clamp(0, images.length).toInt();
        }
      }
      _chapterDownloadedIndexes[chapterId] = {
        for (var index = 0; index < downloaded; index++) index,
      };
      _chapterDownloadedCounts[chapterId] = downloaded;
      if (downloaded >= images.length) {
        _completedChapters.add(chapterId);
      }
    }
  }

  void _recalculateChapterCounts(List<String> chapterIds) {
    _downloadedCount = 0;
    _totalCount = 0;
    for (var chapterId in chapterIds) {
      var images = _images?[chapterId];
      if (images == null) {
        continue;
      }
      _chapterDownloadedIndexes.putIfAbsent(chapterId, () {
        var count = (_chapterDownloadedCounts[chapterId] ?? 0)
            .clamp(0, images.length)
            .toInt();
        return {for (var index = 0; index < count; index++) index};
      });
      _chapterDownloadedIndexes[chapterId]!.removeWhere(
        (index) => index < 0 || index >= images.length,
      );
      var downloaded = _completedChapters.contains(chapterId)
          ? images.length
          : _chapterDownloadedIndexes[chapterId]!.length;
      if (_completedChapters.contains(chapterId) &&
          _chapterDownloadedIndexes[chapterId]!.length < images.length) {
        _chapterDownloadedIndexes[chapterId] = {
          for (var index = 0; index < images.length; index++) index,
        };
      }
      _chapterDownloadedCounts[chapterId] = downloaded;
      _downloadedCount += downloaded;
      _totalCount += images.length;
      if (downloaded >= images.length) {
        _completedChapters.add(chapterId);
      } else {
        _completedChapters.remove(chapterId);
      }
    }
  }

  Future<bool> _ensureChapterImageList(
    String chapterId,
    int totalChapterCount,
  ) async {
    if (_images![chapterId] != null) {
      return true;
    }
    _message = "Fetching image list (${_images!.length}/$totalChapterCount)...";
    notifyListeners();
    var res = await _runWithRetry(() async {
      var r = await source.loadComicPages!(comicId, chapterId);
      if (r.error) {
        throw r.errorMessage!;
      } else {
        return r.data;
      }
    });
    if (!_isRunning) {
      return false;
    }
    if (res.error) {
      Log.error("Download", res.errorMessage!);
      _setError("Error: ${res.errorMessage}");
      return false;
    }
    _images![chapterId] = res.data;
    _chapterDownloadedIndexes.putIfAbsent(chapterId, () => {});
    _chapterDownloadedCounts.putIfAbsent(chapterId, () => 0);
    _recalculateChapterCounts(_downloadChapterIds);
    _message = _chapterProgressMessage();
    notifyListeners();
    await _saveCurrentDownloadingTasksState();
    return true;
  }

  Directory _chapterSaveDirectory(String chapterId) {
    var saveTo = Directory(
      FilePath.join(path!, LocalManager.getChapterDirectoryName(chapterId)),
    );
    if (!saveTo.existsSync()) {
      saveTo.createSync(recursive: true);
    }
    return saveTo;
  }

  bool _hasPendingChapterImages(String chapterId) {
    var images = _images?[chapterId];
    if (images == null) {
      return true;
    }
    var downloaded = _chapterDownloadedIndexes[chapterId] ?? {};
    var active = _chapterTasks[chapterId]?.keys ?? <int>[];
    return downloaded.length + active.length < images.length;
  }

  bool _startNextChapterImageDownload(String chapterId) {
    var images = _images![chapterId]!;
    var downloaded = _chapterDownloadedIndexes.putIfAbsent(chapterId, () => {});
    var active = _chapterTasks.putIfAbsent(chapterId, () => {});
    for (var index = 0; index < images.length; index++) {
      if (downloaded.contains(index) || active.containsKey(index)) {
        continue;
      }
      var task = _ImageDownloadWrapper(
        this,
        chapterId,
        images[index],
        _chapterSaveDirectory(chapterId),
        index,
      );
      active[index] = task;
      _activeChapters.add(chapterId);
      task.wait().then((task) {
        _handleChapterImageDownloadFinished(chapterId, index, task);
      });
      return true;
    }
    return false;
  }

  Future<void> _handleChapterImageDownloadFinished(
    String chapterId,
    int index,
    _ImageDownloadWrapper task,
  ) async {
    if (_chapterTasks[chapterId]?[index] == task) {
      _chapterTasks[chapterId]!.remove(index);
      if (_chapterTasks[chapterId]!.isEmpty) {
        _chapterTasks.remove(chapterId);
      }
    }
    if (!_isRunning || task.isCancelled) {
      _wakeChapterDownloadScheduler();
      return;
    }
    if (task.error != null) {
      Log.error("Download", task.error.toString());
      _setError("Error: ${task.error}");
      _wakeChapterDownloadScheduler();
      return;
    }
    var downloaded = _chapterDownloadedIndexes.putIfAbsent(chapterId, () => {});
    if (downloaded.add(index)) {
      _downloadedCount++;
    }
    _chapterDownloadedCounts[chapterId] = downloaded.length;
    var images = _images?[chapterId];
    var forceSave = false;
    if (images != null && downloaded.length >= images.length) {
      _completedChapters.add(chapterId);
      _activeChapters.remove(chapterId);
      _chapterDownloadedCounts[chapterId] = images.length;
      forceSave = true;
    }
    _recalculateChapterCounts(_downloadChapterIds);
    _message = _chapterProgressMessage();
    notifyListeners();
    _wakeChapterDownloadScheduler();
    await _saveCurrentDownloadingTasksState(force: forceSave);
  }

  Future<void> _waitForChapterDownloadWake(int wakeVersion) async {
    if (_chapterDownloadWakeVersion != wakeVersion) {
      return;
    }
    _chapterDownloadWake = Completer<void>();
    if (_chapterDownloadWakeVersion != wakeVersion) {
      _chapterDownloadWake!.complete();
    }
    await _chapterDownloadWake!.future;
    _chapterDownloadWake = null;
  }

  Future<void> _downloadChaptersConcurrently() async {
    _images ??= {};
    var chapterIds = _downloadChapterIds;
    _migrateLegacyChapterProgress(chapterIds);
    _recalculateChapterCounts(chapterIds);
    _message = _chapterProgressMessage(chapterIds);
    notifyListeners();
    await _saveCurrentDownloadingTasksState(force: true);
    var readyChapters = Queue<String>.from(
      chapterIds.where(
        (chapterId) =>
            !_completedChapters.contains(chapterId) &&
            _images![chapterId] != null &&
            _hasPendingChapterImages(chapterId),
      ),
    );
    var pendingChapters = Queue<String>.from(
      chapterIds.where(
        (chapterId) =>
            !_completedChapters.contains(chapterId) &&
            _images![chapterId] == null,
      ),
    );
    if (pendingChapters.isEmpty && readyChapters.isEmpty) {
      return;
    }
    var fetchingChapters = <String>{};

    void addReadyChapter(String chapterId) {
      if (!readyChapters.contains(chapterId)) {
        readyChapters.add(chapterId);
      }
    }

    void startFetchingChapters() {
      while (_isRunning &&
          !_isError &&
          pendingChapters.isNotEmpty &&
          fetchingChapters.length < _maxConcurrentChapters) {
        var chapterId = pendingChapters.removeFirst();
        fetchingChapters.add(chapterId);
        _activeChapters.add(chapterId);
        _message = _chapterProgressMessage(chapterIds);
        notifyListeners();
        _ensureChapterImageList(chapterId, chapterIds.length).then((success) {
          fetchingChapters.remove(chapterId);
          if (!_isRunning || _isError) {
            _wakeChapterDownloadScheduler();
            return;
          }
          if (success) {
            if (_completedChapters.contains(chapterId)) {
              _activeChapters.remove(chapterId);
            } else if (_hasPendingChapterImages(chapterId) &&
                !readyChapters.contains(chapterId)) {
              addReadyChapter(chapterId);
            }
          } else if (!_hasPendingChapterImages(chapterId)) {
            _activeChapters.remove(chapterId);
          }
          _message = _chapterProgressMessage(chapterIds);
          notifyListeners();
          _wakeChapterDownloadScheduler();
        });
      }
    }

    startFetchingChapters();
    while (_isRunning &&
        !_isError &&
        (pendingChapters.isNotEmpty ||
            fetchingChapters.isNotEmpty ||
            readyChapters.isNotEmpty ||
            _activeChapterImageDownloadCount > 0)) {
      startFetchingChapters();
      var started = false;
      while (_isRunning &&
          !_isError &&
          readyChapters.isNotEmpty &&
          _activeChapterImageDownloadCount < _maxConcurrentTasks) {
        var chapterId = readyChapters.removeFirst();
        if (_completedChapters.contains(chapterId)) {
          _activeChapters.remove(chapterId);
          continue;
        }
        if (_startNextChapterImageDownload(chapterId)) {
          started = true;
          if (_hasPendingChapterImages(chapterId)) {
            addReadyChapter(chapterId);
          }
        } else if (!_hasPendingChapterImages(chapterId)) {
          _activeChapters.remove(chapterId);
        }
      }
      if (started) {
        _message = _chapterProgressMessage(chapterIds);
        notifyListeners();
        continue;
      }
      if (readyChapters.isNotEmpty &&
          _activeChapterImageDownloadCount < _maxConcurrentTasks) {
        continue;
      }
      if (pendingChapters.isNotEmpty &&
          fetchingChapters.length < _maxConcurrentChapters) {
        continue;
      }
      await _waitForChapterDownloadWake(_chapterDownloadWakeVersion);
    }
    _activeChapters.clear();
    _chapterTasks.clear();
    if (!_isRunning || _isError) {
      return;
    }
    _recalculateChapterCounts(chapterIds);
    _message = _chapterProgressMessage(chapterIds);
    notifyListeners();
    await _saveCurrentDownloadingTasksState(force: true);
  }

  @override
  void resume() async {
    if (_isRunning) return;
    _isError = false;
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
      if (!_isRunning) {
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

    await LocalManager().saveCurrentDownloadingTasks();

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
      await LocalManager().saveCurrentDownloadingTasks();
    }

    if (comic!.chapters != null) {
      await _downloadChaptersConcurrently();
      if (!_isRunning || _isError) {
        return;
      }
      LocalManager().completeTask(this);
      stopRecorder();
      return;
    }

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
      if (!_isRunning) {
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
      _message = "$_downloadedCount/$_totalCount";
      notifyListeners();
      await LocalManager().saveCurrentDownloadingTasks();
    }

    while (_chapter < _images!.length) {
      var images = _images![_images!.keys.elementAt(_chapter)]!;
      tasks.clear();
      while (_index < images.length) {
        _scheduleTasks();
        var task = tasks[_index]!;
        await task.wait();
        if (isPaused) {
          return;
        }
        if (task.error != null) {
          Log.error("Download", task.error.toString());
          _setError("Error: ${task.error}");
          return;
        }
        _index++;
        _downloadedCount++;
        _message = "$_downloadedCount/$_totalCount";
        await LocalManager().saveCurrentDownloadingTasks();
      }
      _index = 0;
      _chapter++;
    }

    LocalManager().completeTask(this);
    stopRecorder();
  }

  @override
  void onNextSecond(Timer t) {
    notifyListeners();
    super.onNextSecond(t);
  }

  void _setError(String message) {
    _isRunning = false;
    _isError = true;
    _message = message;
    _cancelActiveDownloads();
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
      "chapterDownloadedCounts": _chapterDownloadedCounts,
      "chapterDownloadedIndexes": _chapterDownloadedIndexes.map(
        (chapterId, indexes) => MapEntry(chapterId, indexes.toList()),
      ),
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

    var chapterDownloadedCounts = <String, int>{};
    if (json["chapterDownloadedCounts"] != null) {
      for (var entry in json["chapterDownloadedCounts"].entries) {
        chapterDownloadedCounts[entry.key] = (entry.value as num).toInt();
      }
    }

    var chapterDownloadedIndexes = <String, Set<int>>{};
    if (json["chapterDownloadedIndexes"] != null) {
      for (var entry in json["chapterDownloadedIndexes"].entries) {
        chapterDownloadedIndexes[entry.key] = {
          for (var value in entry.value) (value as num).toInt(),
        };
      }
    }

    return ImagesDownloadTask(
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
      .._downloadedCount = json["downloadedCount"] ?? 0
      .._totalCount = json["totalCount"] ?? 0
      .._index = json["index"] ?? 0
      .._chapter = json["chapter"] ?? 0
      .._chapterDownloadedCounts.addAll(chapterDownloadedCounts)
      .._chapterDownloadedIndexes.addAll(chapterDownloadedIndexes)
      .._completedChapters.addAll(
        List<String>.from(json["completedChapters"] ?? []),
      );
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

  _ImageDownloadWrapper(
    this.task,
    this.chapter,
    this.image,
    this.saveTo,
    this.index,
  ) {
    start();
  }

  bool isComplete = false;

  String? error;

  bool isCancelled = false;

  void cancel() {
    isCancelled = true;
    for (var c in completers) {
      if (!c.isCompleted) {
        c.complete(this);
      }
    }
    completers.clear();
  }

  var completers = <Completer<_ImageDownloadWrapper>>[];

  var retry = 3;

  void start() async {
    int lastBytes = 0;
    try {
      await for (var p in ImageDownloader.downloadComicImageToFile(
        image,
        task.source.key,
        task.comicId,
        chapter,
        saveTo,
        index,
      )) {
        if (isCancelled) {
          return;
        }
        task.onData(p.currentBytes - lastBytes);
        lastBytes = p.currentBytes;
        if (p.imageBytes != null) {
          isComplete = true;
          for (var c in completers) {
            c.complete(this);
          }
          completers.clear();
        }
      }
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
      for (var c in completers) {
        if (!c.isCompleted) {
          c.complete(this);
        }
      }
    }
  }

  Future<_ImageDownloadWrapper> wait() {
    if (isComplete || isCancelled) {
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
