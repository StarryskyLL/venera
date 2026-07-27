import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/network/comic_image_file_writer.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('venera-image-writer-');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'streams chunks in order and atomically creates the image file',
    () async {
      final chunks = [
        Uint8List.fromList([0x89, 0x50, 0x4e, 0x47]),
        Uint8List.fromList([0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3]),
      ];
      final basePath = '${tempDir.path}${Platform.pathSeparator}0';

      final progress = await ComicImageFileWriter.writeStream(
        Stream.fromIterable(chunks),
        basePath,
      ).toList();

      expect(progress, [4, 11]);
      expect(
        await File('$basePath.png').readAsBytes(),
        chunks.expand((e) => e),
      );
      expect(await File('$basePath.download').exists(), isFalse);
    },
  );

  test('removes the temporary file when the response stream fails', () async {
    final basePath = '${tempDir.path}${Platform.pathSeparator}1';

    Stream<Uint8List> failingStream() async* {
      yield Uint8List.fromList([0xff, 0xd8, 0xff]);
      throw StateError('network failed');
    }

    await expectLater(
      ComicImageFileWriter.writeStream(failingStream(), basePath).drain<void>(),
      throwsStateError,
    );
    expect(await File('$basePath.download').exists(), isFalse);
    expect(await File('$basePath.jpg').exists(), isFalse);
  });

  test('writes transformed bytes through a temporary file', () async {
    final basePath = '${tempDir.path}${Platform.pathSeparator}2';
    final data = Uint8List.fromList([0xff, 0xd8, 0xff, 1, 2, 3]);

    final saved = await ComicImageFileWriter.writeBytes(basePath, data);

    expect(saved.path, '$basePath.jpg');
    expect(await saved.readAsBytes(), data);
    expect(await File('$basePath.download').exists(), isFalse);
  });
}
