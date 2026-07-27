import 'dart:io';
import 'dart:typed_data';

import 'package:venera/utils/file_type.dart';

abstract final class ComicImageFileWriter {
  static Stream<int> writeStream(
    Stream<Uint8List> stream,
    String savePathWithoutExtension,
  ) async* {
    final temporaryFile = File('$savePathWithoutExtension.download');
    IOSink? sink;
    var committed = false;
    var currentBytes = 0;
    final header = BytesBuilder(copy: false);
    try {
      sink = temporaryFile.openWrite();
      await for (final data in stream) {
        if (header.length < 32) {
          final remaining = 32 - header.length;
          header.add(
            data.length <= remaining ? data : data.sublist(0, remaining),
          );
        }
        sink.add(data);
        currentBytes += data.length;
        yield currentBytes;
      }
      await sink.flush();
      await sink.close();
      sink = null;

      final fileType = detectFileType(header.takeBytes());
      final destination = File('$savePathWithoutExtension${fileType.ext}');
      if (await destination.exists()) {
        await destination.delete();
      }
      await temporaryFile.rename(destination.path);
      committed = true;
    } finally {
      if (sink != null) {
        try {
          await sink.close();
        } catch (_) {}
      }
      if (!committed && await temporaryFile.exists()) {
        await temporaryFile.delete();
      }
    }
  }

  static Future<File> writeBytes(
    String savePathWithoutExtension,
    Uint8List data,
  ) async {
    final fileType = detectFileType(data);
    final temporaryFile = File('$savePathWithoutExtension.download');
    final destination = File('$savePathWithoutExtension${fileType.ext}');
    var committed = false;
    try {
      await temporaryFile.writeAsBytes(data);
      if (await destination.exists()) {
        await destination.delete();
      }
      final savedFile = await temporaryFile.rename(destination.path);
      committed = true;
      return savedFile;
    } finally {
      if (!committed && await temporaryFile.exists()) {
        await temporaryFile.delete();
      }
    }
  }
}
