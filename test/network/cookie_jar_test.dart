import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/network/cookie_jar.dart';

void main() {
  late Directory tempDir;
  late CookieJarSql cookieJar;
  final uri = Uri.parse('https://images.example.com/chapter/page.jpg');

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('venera-cookie-jar-');
    cookieJar = CookieJarSql(
      '${tempDir.path}${Platform.pathSeparator}cookies.db',
    );
  });

  tearDown(() async {
    cookieJar.dispose();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('cached domain cookies are invalidated after an update', () {
    cookieJar.saveFromResponse(uri, [Cookie('token', 'first')]);
    expect(cookieJar.loadForRequestCookieHeader(uri), 'token=first');

    cookieJar.saveFromResponse(uri, [Cookie('token', 'second')]);

    expect(cookieJar.loadForRequestCookieHeader(uri), 'token=second');
  });

  test('cached domain cookies are invalidated after deletion', () {
    cookieJar.saveFromResponse(uri, [Cookie('token', 'value')]);
    expect(cookieJar.loadForRequestCookieHeader(uri), 'token=value');

    cookieJar.deleteUri(uri);

    expect(cookieJar.loadForRequestCookieHeader(uri), isEmpty);
  });
}
