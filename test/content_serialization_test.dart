import 'package:dio/dio.dart';
import 'package:dio_cache_interceptor/src/util/content_serialization.dart';
import 'package:test/test.dart';

void main() {
  test('Serialize bytes', () async {
    final content = 'test'.codeUnits;

    final serializedContent = await serializeContent(
      ResponseType.bytes,
      content,
    );
    final deserializedContent = await deserializeContent(
      ResponseType.bytes,
      serializedContent,
    );
    expect(deserializedContent, equals(content));
  });

  test('Serialize stream', () async {
    Stream<List<int>> content() async* {
      yield 'test'.codeUnits;
    }

    final serializedContent = await serializeContent(
      ResponseType.stream,
      content(),
    );
    final deserializedContent = await deserializeContent(
      ResponseType.stream,
      serializedContent,
    );
    expect(
      await (deserializedContent as Stream<List<int>>).first,
      equals(await content().first),
    );
  });

  test('Serialize plain', () async {
    final content = 'test';

    final serializedContent = await serializeContent(
      ResponseType.plain,
      content,
    );
    final deserializedContent = await deserializeContent(
      ResponseType.plain,
      serializedContent,
    );
    expect(deserializedContent, equals(content));
  });

  test('Serialize json', () async {
    final content = {'test': 'value'};

    final serializedContent = await serializeContent(
      ResponseType.json,
      content,
    );
    final deserializedContent = await deserializeContent(
      ResponseType.json,
      serializedContent,
    );
    expect(deserializedContent, equals(content));
  });
}
