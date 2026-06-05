import 'dart:async';

import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/file_type.dart';
import 'package:venera/utils/image.dart';
import 'package:venera/utils/io.dart';

import 'app_dio.dart';

const _downloadTimingMaxLogs = 80;
var _downloadTimingLogs = 0;

String _safeDownloadHost(String url) {
  try {
    return Uri.parse(url).host;
  } catch (_) {
    return '';
  }
}

void _logSlowImageDownloadTiming({
  required String imageKey,
  required String? sourceKey,
  required String cid,
  required String eid,
  required int index,
  required int bytes,
  required bool needsProcessing,
  required bool hasOnResponse,
  required bool hasModifyImage,
  required int totalMs,
  required int configMs,
  required int? requestMs,
  required int? firstChunkMs,
  required int? streamMs,
  required int? closeMs,
  required int? processMs,
  required int? detectMs,
  required int? renameMs,
  bool usedDirectClient = false,
  Object? error,
}) {
  var slow =
      totalMs >= 1200 ||
      configMs >= 500 ||
      (requestMs ?? 0) >= 800 ||
      (firstChunkMs ?? 0) >= 800 ||
      (streamMs ?? 0) >= 800 ||
      (processMs ?? 0) >= 500 ||
      (renameMs ?? 0) >= 300 ||
      error != null;
  if (!slow || _downloadTimingLogs >= _downloadTimingMaxLogs) {
    return;
  }
  _downloadTimingLogs++;
  var status = error == null ? "ok" : "error=${error.toString()}";
  Log.info(
    "DownloadTiming",
    "image $status source=$sourceKey cid=$cid eid=$eid index=$index "
        "host=${_safeDownloadHost(imageKey)} bytes=$bytes "
        "direct=$usedDirectClient processed=$needsProcessing onResponse=$hasOnResponse "
        "modifyImage=$hasModifyImage total=${totalMs}ms "
        "config=${configMs}ms request=${requestMs ?? -1}ms "
        "firstChunk=${firstChunkMs ?? -1}ms stream=${streamMs ?? -1}ms "
        "close=${closeMs ?? -1}ms process=${processMs ?? -1}ms "
        "detect=${detectMs ?? -1}ms rename=${renameMs ?? -1}ms",
  );
}

String _normalizeImageDownloadUrl(String url) {
  if (url.startsWith('//')) {
    return 'https:$url';
  }
  return url;
}

bool _isHttpImageDownloadUrl(String url) {
  var uri = Uri.tryParse(url);
  return uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
}

bool _canUseDirectImageDownload(Map<String, dynamic> configs, String url) {
  var method = (configs['method'] ?? 'GET').toString().toUpperCase();
  var headers = configs['headers'];
  var preventParallel = headers is Map && headers['prevent-parallel'] == 'true';
  return method == 'GET' &&
      configs['data'] == null &&
      configs['onLoadFailed'] is! JSInvokable &&
      configs['onResponse'] is! JSInvokable &&
      configs['modifyImage'] == null &&
      !preventParallel &&
      _isHttpImageDownloadUrl(url);
}

Future<Response<ResponseBody>> _requestImageDownload({
  required String url,
  required Map<String, dynamic> configs,
  required bool useDirectClient,
}) {
  if (useDirectClient) {
    return ImageDownloader._directDownloadDio.request<ResponseBody>(
      url,
      options: Options(
        method: 'GET',
        headers: Map<String, dynamic>.from(configs['headers']),
        responseType: ResponseType.stream,
      ),
    );
  }
  var dio = AppDio(
    BaseOptions(
      headers: Map<String, dynamic>.from(configs['headers']),
      method: configs['method'] ?? 'GET',
      responseType: ResponseType.stream,
    ),
  );
  return dio.request<ResponseBody>(
    url,
    data: configs['data'],
    options: Options(
      method: configs['method'] ?? 'GET',
      responseType: ResponseType.stream,
      extra: {'skipLog': true, 'skipMemoryCache': true},
    ),
  );
}

abstract class ImageDownloader {
  static final Dio _directDownloadDio = Dio(
    BaseOptions(responseType: ResponseType.stream),
  )..httpClientAdapter = RHttpAdapter();

  static Stream<ImageDownloadProgress> loadThumbnail(
    String url,
    String? sourceKey, [
    String? cid,
  ]) async* {
    final cacheKey = "$url@$sourceKey${cid != null ? '@$cid' : ''}";
    final cache = await CacheManager().findCache(cacheKey);

    if (cache != null) {
      var data = await cache.readAsBytes();
      yield ImageDownloadProgress(
        currentBytes: data.length,
        totalBytes: data.length,
        imageBytes: data,
      );
    }

    var configs = <String, dynamic>{};
    if (sourceKey != null) {
      var comicSource = ComicSource.find(sourceKey);
      configs = comicSource?.getThumbnailLoadingConfig?.call(url) ?? {};
    }
    configs['headers'] ??= {};
    if (configs['headers']['user-agent'] == null &&
        configs['headers']['User-Agent'] == null) {
      configs['headers']['user-agent'] = webUA;
    }

    if (((configs['url'] as String?) ?? url).startsWith('cover.') &&
        sourceKey != null) {
      var comicSource = ComicSource.find(sourceKey);
      if (comicSource != null) {
        var comicInfo = await comicSource.loadComicInfo!(cid!);
        yield* loadThumbnail(comicInfo.data.cover, sourceKey);
        return;
      }
    }

    var dio = AppDio(
      BaseOptions(
        headers: Map<String, dynamic>.from(configs['headers']),
        method: configs['method'] ?? 'GET',
        responseType: ResponseType.stream,
      ),
    );

    String requestUrl = configs['url'] ?? url;
    if (requestUrl.startsWith('//')) {
      requestUrl = 'https:$requestUrl';
    }
    var req = await dio.request<ResponseBody>(
      requestUrl,
      data: configs['data'],
    );
    var stream = req.data?.stream ?? (throw "Error: Empty response body.");
    int? expectedBytes = req.data!.contentLength;
    if (expectedBytes == -1) {
      expectedBytes = null;
    }
    var buffer = <int>[];
    await for (var data in stream) {
      buffer.addAll(data);
      if (expectedBytes != null) {
        yield ImageDownloadProgress(
          currentBytes: buffer.length,
          totalBytes: expectedBytes,
        );
      }
    }

    if (configs['onResponse'] is JSInvokable) {
      final uint8List = Uint8List.fromList(buffer);
      buffer = (configs['onResponse'] as JSInvokable)([uint8List]);
      (configs['onResponse'] as JSInvokable).free();
    }

    await CacheManager().writeCache(cacheKey, buffer);
    yield ImageDownloadProgress(
      currentBytes: buffer.length,
      totalBytes: buffer.length,
      imageBytes: Uint8List.fromList(buffer),
    );
  }

  static final _loadingImages =
      <String, _StreamWrapper<ImageDownloadProgress>>{};

  /// Cancel all loading images.
  static void cancelAllLoadingImages() {
    for (var wrapper in _loadingImages.values) {
      wrapper.cancel();
    }
    _loadingImages.clear();
  }

  /// Load a comic image from the network or cache.
  /// The function will prevent multiple requests for the same image.
  static Stream<ImageDownloadProgress> loadComicImage(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid,
  ) {
    final cacheKey = "$imageKey@$sourceKey@$cid@$eid";
    if (_loadingImages.containsKey(cacheKey)) {
      return _loadingImages[cacheKey]!.stream;
    }
    final stream = _StreamWrapper<ImageDownloadProgress>(
      _loadComicImage(imageKey, sourceKey, cid, eid),
      (wrapper) {
        _loadingImages.remove(cacheKey);
      },
    );
    _loadingImages[cacheKey] = stream;
    return stream.stream;
  }

  static Stream<ImageDownloadProgress> loadComicImageUnwrapped(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid,
  ) {
    return _loadComicImage(imageKey, sourceKey, cid, eid);
  }

  static Stream<ImageDownloadProgress> downloadComicImageToFile(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid,
    Directory saveTo,
    int index,
  ) async* {
    final totalWatch = Stopwatch()..start();
    final configWatch = Stopwatch()..start();
    final tempFile = saveTo.joinFile(".$index.downloading");
    var isFinished = false;

    Future<Map<String, dynamic>?> Function()? onLoadFailed;
    var configs = <String, dynamic>{};
    if (sourceKey != null) {
      var comicSource = ComicSource.find(sourceKey);
      configs =
          (await comicSource!.getImageLoadingConfig?.call(
            imageKey,
            cid,
            eid,
          )) ??
          {};
    }
    configWatch.stop();
    int? requestMs;
    int? firstChunkMs;
    int? streamMs;
    int? closeMs;
    int? processMs;
    int? detectMs;
    int? renameMs;
    var lastDownloadedBytes = 0;
    var needsProcessingForLog = false;
    var hasOnResponseForLog = false;
    var hasModifyImageForLog = false;
    var usedDirectClientForLog = false;
    var retryLimit = 5;
    try {
      while (true) {
        try {
          configs['headers'] ??= {'user-agent': webUA};

          if (configs['onLoadFailed'] is JSInvokable) {
            onLoadFailed = () async {
              dynamic result = (configs['onLoadFailed'] as JSInvokable)([]);
              if (result is Future) {
                result = await result;
              }
              if (result is! Map<String, dynamic>) return null;
              return result;
            };
          }

          var requestUrl = _normalizeImageDownloadUrl(
            (configs['url'] ?? imageKey).toString(),
          );
          var useDirectClient = _canUseDirectImageDownload(configs, requestUrl);
          usedDirectClientForLog = useDirectClient;

          var requestWatch = Stopwatch()..start();
          late Response<ResponseBody> req;
          try {
            req = await _requestImageDownload(
              url: requestUrl,
              configs: configs,
              useDirectClient: useDirectClient,
            );
          } catch (_) {
            if (!useDirectClient) {
              rethrow;
            }
            usedDirectClientForLog = false;
            req = await _requestImageDownload(
              url: requestUrl,
              configs: configs,
              useDirectClient: false,
            );
          }
          requestWatch.stop();
          requestMs = requestWatch.elapsedMilliseconds;
          var stream =
              req.data?.stream ?? (throw "Error: Empty response body.");
          int? expectedBytes = req.data!.contentLength;
          if (expectedBytes == -1) {
            expectedBytes = null;
          }

          var needsProcessing =
              configs['onResponse'] is JSInvokable ||
              configs['modifyImage'] != null;
          needsProcessingForLog = needsProcessing;
          hasOnResponseForLog = configs['onResponse'] is JSInvokable;
          hasModifyImageForLog = configs['modifyImage'] != null;
          var downloaded = 0;
          List<int>? buffer;
          IOSink? sink;
          if (needsProcessing) {
            buffer = <int>[];
          } else {
            await tempFile.parent.create(recursive: true);
            sink = tempFile.openWrite();
          }

          try {
            var streamWatch = Stopwatch()..start();
            var firstChunkWatch = Stopwatch()..start();
            await for (var data in stream) {
              firstChunkMs ??= firstChunkWatch.elapsedMilliseconds;
              downloaded += data.length;
              lastDownloadedBytes = downloaded;
              if (buffer != null) {
                buffer.addAll(data);
              } else {
                sink!.add(data);
              }
              yield ImageDownloadProgress(
                currentBytes: downloaded,
                totalBytes: expectedBytes,
              );
            }
            streamWatch.stop();
            streamMs = streamWatch.elapsedMilliseconds;
          } finally {
            var closeWatch = Stopwatch()..start();
            await sink?.close();
            closeWatch.stop();
            closeMs = closeWatch.elapsedMilliseconds;
          }

          late Uint8List imageBytes;
          var processWatch = Stopwatch()..start();
          if (buffer != null) {
            if (configs['onResponse'] is JSInvokable) {
              try {
                dynamic result = (configs['onResponse'] as JSInvokable)([
                  Uint8List.fromList(buffer),
                ]);
                if (result is Future) {
                  result = await result;
                }
                if (result is List<int>) {
                  buffer = result;
                } else {
                  throw "Error: Invalid onResponse result.";
                }
              } finally {
                (configs['onResponse'] as JSInvokable).free();
              }
            }

            imageBytes = buffer is Uint8List
                ? buffer
                : Uint8List.fromList(buffer);
            if (configs['modifyImage'] != null) {
              imageBytes = await modifyImageWithScript(
                imageBytes,
                configs['modifyImage'],
              );
            }
            await tempFile.writeAsBytes(imageBytes);
          } else {
            imageBytes = await tempFile
                .openRead(0, 64)
                .fold<BytesBuilder>(BytesBuilder(copy: false), (builder, data) {
                  builder.add(data);
                  return builder;
                })
                .then((builder) => builder.takeBytes());
          }
          processWatch.stop();
          processMs = processWatch.elapsedMilliseconds;

          var detectWatch = Stopwatch()..start();
          var fileType = detectFileType(imageBytes);
          detectWatch.stop();
          detectMs = detectWatch.elapsedMilliseconds;
          var resultFile = saveTo.joinFile("$index${fileType.ext}");
          if (await resultFile.exists()) {
            await resultFile.delete();
          }
          var renameWatch = Stopwatch()..start();
          await tempFile.rename(resultFile.path);
          renameWatch.stop();
          renameMs = renameWatch.elapsedMilliseconds;
          isFinished = true;
          yield ImageDownloadProgress(
            currentBytes: downloaded,
            totalBytes: downloaded,
            imageBytes: imageBytes,
          );
          _logSlowImageDownloadTiming(
            imageKey: configs['url'] ?? imageKey,
            sourceKey: sourceKey,
            cid: cid,
            eid: eid,
            index: index,
            bytes: downloaded,
            needsProcessing: needsProcessingForLog,
            hasOnResponse: hasOnResponseForLog,
            hasModifyImage: hasModifyImageForLog,
            totalMs: totalWatch.elapsedMilliseconds,
            configMs: configWatch.elapsedMilliseconds,
            requestMs: requestMs,
            firstChunkMs: firstChunkMs,
            streamMs: streamMs,
            closeMs: closeMs,
            processMs: processMs,
            detectMs: detectMs,
            renameMs: renameMs,
            usedDirectClient: usedDirectClientForLog,
          );
          return;
        } catch (e) {
          await tempFile.deleteIgnoreError();
          if (retryLimit < 0 || onLoadFailed == null) {
            rethrow;
          }
          var newConfig = await onLoadFailed();
          (configs['onLoadFailed'] as JSInvokable).free();
          onLoadFailed = null;
          if (newConfig == null) {
            rethrow;
          }
          configs = newConfig;
          retryLimit--;
        } finally {
          if (onLoadFailed != null) {
            (configs['onLoadFailed'] as JSInvokable).free();
            onLoadFailed = null;
          }
        }
      }
    } catch (e) {
      _logSlowImageDownloadTiming(
        imageKey: configs['url'] ?? imageKey,
        sourceKey: sourceKey,
        cid: cid,
        eid: eid,
        index: index,
        bytes: lastDownloadedBytes,
        needsProcessing: needsProcessingForLog,
        hasOnResponse: hasOnResponseForLog,
        hasModifyImage: hasModifyImageForLog,
        totalMs: totalWatch.elapsedMilliseconds,
        configMs: configWatch.elapsedMilliseconds,
        requestMs: requestMs,
        firstChunkMs: firstChunkMs,
        streamMs: streamMs,
        closeMs: closeMs,
        processMs: processMs,
        detectMs: detectMs,
        renameMs: renameMs,
        usedDirectClient: usedDirectClientForLog,
        error: e,
      );
      rethrow;
    } finally {
      if (!isFinished) {
        await tempFile.deleteIgnoreError();
      }
    }
  }

  static Stream<ImageDownloadProgress> _loadComicImage(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid,
  ) async* {
    final cacheKey = "$imageKey@$sourceKey@$cid@$eid";
    final cache = await CacheManager().findCache(cacheKey);

    if (cache != null) {
      var data = await cache.readAsBytes();
      yield ImageDownloadProgress(
        currentBytes: data.length,
        totalBytes: data.length,
        imageBytes: data,
      );
      return;
    }

    Future<Map<String, dynamic>?> Function()? onLoadFailed;

    var configs = <String, dynamic>{};
    if (sourceKey != null) {
      var comicSource = ComicSource.find(sourceKey);
      configs =
          (await comicSource!.getImageLoadingConfig?.call(
            imageKey,
            cid,
            eid,
          )) ??
          {};
    }
    var retryLimit = 5;
    while (true) {
      try {
        configs['headers'] ??= {'user-agent': webUA};

        if (configs['onLoadFailed'] is JSInvokable) {
          onLoadFailed = () async {
            dynamic result = (configs['onLoadFailed'] as JSInvokable)([]);
            if (result is Future) {
              result = await result;
            }
            if (result is! Map<String, dynamic>) return null;
            return result;
          };
        }

        var dio = AppDio(
          BaseOptions(
            headers: configs['headers'],
            method: configs['method'] ?? 'GET',
            responseType: ResponseType.stream,
          ),
        );

        var req = await dio.request<ResponseBody>(
          configs['url'] ?? imageKey,
          data: configs['data'],
        );
        var stream = req.data?.stream ?? (throw "Error: Empty response body.");
        int? expectedBytes = req.data!.contentLength;
        if (expectedBytes == -1) {
          expectedBytes = null;
        }
        var buffer = <int>[];
        await for (var data in stream) {
          buffer.addAll(data);
          yield ImageDownloadProgress(
            currentBytes: buffer.length,
            totalBytes: expectedBytes,
          );
        }

        if (configs['onResponse'] is JSInvokable) {
          dynamic result = (configs['onResponse'] as JSInvokable)([
            Uint8List.fromList(buffer),
          ]);
          if (result is Future) {
            result = await result;
          }
          if (result is List<int>) {
            buffer = result;
          } else {
            throw "Error: Invalid onResponse result.";
          }
          (configs['onResponse'] as JSInvokable).free();
        }

        Uint8List data;
        if (buffer is Uint8List) {
          data = buffer;
        } else {
          data = Uint8List.fromList(buffer);
          buffer.clear();
        }

        if (configs['modifyImage'] != null) {
          var newData = await modifyImageWithScript(
            data,
            configs['modifyImage'],
          );
          data = newData;
        }

        await CacheManager().writeCache(cacheKey, data);
        yield ImageDownloadProgress(
          currentBytes: data.length,
          totalBytes: data.length,
          imageBytes: data,
        );
        return;
      } catch (e) {
        if (retryLimit < 0 || onLoadFailed == null) {
          rethrow;
        }
        var newConfig = await onLoadFailed();
        (configs['onLoadFailed'] as JSInvokable).free();
        onLoadFailed = null;
        if (newConfig == null) {
          rethrow;
        }
        configs = newConfig;
        retryLimit--;
      } finally {
        if (onLoadFailed != null) {
          (configs['onLoadFailed'] as JSInvokable).free();
        }
      }
    }
  }
}

/// A wrapper class for a stream that
/// allows multiple listeners to listen to the same stream.
class _StreamWrapper<T> {
  final Stream<T> _stream;

  final List<StreamController> controllers = [];

  final void Function(_StreamWrapper<T> wrapper) onClosed;

  bool isClosed = false;

  _StreamWrapper(this._stream, this.onClosed) {
    _listen();
  }

  void _listen() async {
    try {
      await for (var data in _stream) {
        if (isClosed) {
          break;
        }
        for (var controller in controllers) {
          if (!controller.isClosed) {
            controller.add(data);
          }
        }
      }
    } catch (e) {
      for (var controller in controllers) {
        if (!controller.isClosed) {
          controller.addError(e);
        }
      }
    } finally {
      for (var controller in controllers) {
        if (!controller.isClosed) {
          controller.close();
        }
      }
    }
    controllers.clear();
    isClosed = true;
    onClosed(this);
  }

  Stream<T> get stream {
    if (isClosed) {
      throw Exception('Stream is closed');
    }
    var controller = StreamController<T>();
    controllers.add(controller);
    controller.onCancel = () {
      controllers.remove(controller);
    };
    return controller.stream;
  }

  void cancel() {
    for (var controller in controllers) {
      controller.close();
    }
    controllers.clear();
    isClosed = true;
  }
}

class ImageDownloadProgress {
  final int currentBytes;

  final int? totalBytes;

  final Uint8List? imageBytes;

  const ImageDownloadProgress({
    required this.currentBytes,
    required this.totalBytes,
    this.imageBytes,
  });
}
