import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:buck_wallet/bootstrap/bootstrap_lkg_cache.dart';
import 'package:buck_wallet/bootstrap/bootstrap_parser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _validDocument = '''{
  "configVersion": 1,
  "network": "BUCK",
  "futureTopLevel": {"keep": true},
  "servers": [
    {"id":"second","displayName":"Tükör 🦌","grpcUrl":"https://two.example","priority":20,"enabled":false,"futureServer":"kept"},
    {"id":"first","displayName":"Primary","grpcUrl":"https://one.example","priority":10,"enabled":true}
  ]
}''';

void main() {
  late Directory root;
  late BootstrapParser parser;
  late File cacheFile;
  late File temporaryFile;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('buck-lkg-cache-test-');
    parser = const BootstrapParser();
    cacheFile = File(p.join(root.path, bootstrapLkgCacheFilename));
    temporaryFile = File(p.join(root.path, bootstrapLkgCacheTemporaryFilename));
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  FileBootstrapCache cache({BootstrapCacheFileOperations? operations}) =>
      FileBootstrapCache(
        directoryProvider: () async => root,
        fileOperations: operations ?? const IoBootstrapCacheFileOperations(),
      );

  Future<BootstrapParseResult> validParsed() => parser.parse(_validDocument);

  group('missing and delete behavior', () {
    test('load missing is a successful not-found result', () async {
      final result = await cache().load();
      expect(result.success, isTrue);
      expect(result.found, isFalse);
      expect(result.failureCategory, BootstrapCacheFailureCategory.notFound);
    });

    test('delete missing is a successful no-op', () async {
      final result = await cache().delete();
      expect(result.success, isTrue);
      expect(result.existed, isFalse);
    });

    test('delete removes cache and stale temp but not sibling', () async {
      final sibling = File(p.join(root.path, 'unrelated.txt'));
      await cacheFile.writeAsString('cache');
      await temporaryFile.writeAsString('temp');
      await sibling.writeAsString('keep');

      final result = await cache().delete();
      expect(result.success, isTrue);
      expect(result.existed, isTrue);
      expect(await cacheFile.exists(), isFalse);
      expect(await temporaryFile.exists(), isFalse);
      expect(await sibling.readAsString(), 'keep');
    });
  });

  group('successful save and load', () {
    test('preserves exact original text, parse result, unicode, and unknowns',
        () async {
      final parsed = await validParsed();
      final saved =
          await cache().saveValidated(document: _validDocument, parsed: parsed);
      final loaded = await cache().load();

      expect(saved.success, isTrue);
      expect(saved.atomicReplacementCompleted, isTrue);
      expect(saved.byteCount, utf8.encode(_validDocument).length);
      expect(loaded.success, isTrue);
      expect(loaded.found, isTrue);
      expect(loaded.document, _validDocument);
      expect(loaded.parsed!.success, isTrue);
      expect(loaded.parsed!.servers.first.id, 'first');
      expect(loaded.parsed!.servers.last.displayName, 'Tükör 🦌');
      expect(loaded.parsed!.unknownFieldCount, 2);
    });

    test('uses fixed final and temporary sibling names', () async {
      final operations = RecordingOperations();
      final parsed = await validParsed();
      await cache(operations: operations)
          .saveValidated(document: _validDocument, parsed: parsed);

      expect(p.basename(operations.writtenPath!),
          bootstrapLkgCacheTemporaryFilename);
      expect(p.basename(operations.renamedDestination!),
          bootstrapLkgCacheFilename);
      expect(await temporaryFile.exists(), isFalse);
    });

    test('elapsed milliseconds can be injected', () async {
      final times = [7, 10].iterator;
      final subject = FileBootstrapCache(
        directoryProvider: () async => root,
        elapsedMilliseconds: () {
          times.moveNext();
          return times.current;
        },
      );
      final parsed = await validParsed();
      final result =
          await subject.saveValidated(document: _validDocument, parsed: parsed);
      expect(result.elapsedMilliseconds, 3);
    });
  });

  group('save validation', () {
    test('rejects supplied unsuccessful parse without writing', () async {
      final invalid = await parser.parse('{');
      final result = await cache()
          .saveValidated(document: _validDocument, parsed: invalid);
      expect(result.failureCategory,
          BootstrapCacheFailureCategory.invalidDocument);
      expect(await cacheFile.exists(), isFalse);
    });

    test('internally reparses and rejects invalid JSON and schema', () async {
      final parsed = await validParsed();
      for (final document in ['{', '{"configVersion":1}']) {
        final result =
            await cache().saveValidated(document: document, parsed: parsed);
        expect(result.success, isFalse);
        expect(result.failureCategory,
            BootstrapCacheFailureCategory.invalidDocument);
      }
      expect(await cacheFile.exists(), isFalse);
    });

    test('rejects mismatched parsed semantics and deterministic order',
        () async {
      final other = await parser.parse(_validDocument.replaceFirst(
          'https://one.example', 'https://different.example'));
      final result =
          await cache().saveValidated(document: _validDocument, parsed: other);
      expect(result.success, isFalse);
      expect(await cacheFile.exists(), isFalse);
    });

    test('rejects mismatched enabled value', () async {
      final other = await parser.parse(
          _validDocument.replaceFirst('"enabled":true', '"enabled":false'));
      final result =
          await cache().saveValidated(document: _validDocument, parsed: other);
      expect(result.success, isFalse);
    });

    test('rejects oversized UTF-8 bytes and preserves valid cache', () async {
      await cacheFile.writeAsString(_validDocument);
      final parsed = await validParsed();
      final oversized = '${List.filled(32768, 'é').join()}x';
      final result =
          await cache().saveValidated(document: oversized, parsed: parsed);
      expect(result.failureCategory, BootstrapCacheFailureCategory.sizeLimit);
      expect(result.byteCount, 65537);
      expect(await cacheFile.readAsString(), _validDocument);
    });
  });

  group('atomic failures', () {
    test('write failure preserves existing cache and returns typed failure',
        () async {
      await cacheFile.writeAsString(_validDocument);
      final operations = RecordingOperations(failWrite: true);
      final result = await cache(operations: operations)
          .saveValidated(document: _validDocument, parsed: await validParsed());
      expect(result.failureCategory, BootstrapCacheFailureCategory.write);
      expect(result.atomicReplacementCompleted, isFalse);
      expect(await cacheFile.readAsString(), _validDocument);
      expect(await temporaryFile.exists(), isFalse);
    });

    test('flush failure preserves existing cache', () async {
      await cacheFile.writeAsString(_validDocument);
      final operations = RecordingOperations(failFlush: true);
      final result = await cache(operations: operations)
          .saveValidated(document: _validDocument, parsed: await validParsed());
      expect(result.failureCategory, BootstrapCacheFailureCategory.flush);
      expect(await cacheFile.readAsString(), _validDocument);
    });

    test('rename failure preserves existing cache and later save recovers',
        () async {
      await cacheFile.writeAsString(_validDocument);
      final operations = RecordingOperations(failRename: true);
      final failed = await cache(operations: operations)
          .saveValidated(document: _validDocument, parsed: await validParsed());
      expect(failed.failureCategory, BootstrapCacheFailureCategory.rename);
      expect(await cacheFile.readAsString(), _validDocument);
      expect(await temporaryFile.exists(), isFalse);

      final recovered = await cache()
          .saveValidated(document: _validDocument, parsed: await validParsed());
      expect(recovered.success, isTrue);
      expect(await temporaryFile.exists(), isFalse);
    });
  });

  group('load corruption is preserved but unusable', () {
    test('rejects oversized cache before reading', () async {
      await cacheFile.writeAsBytes(Uint8List(65537));
      final operations = RecordingOperations(failRead: true);
      final result = await cache(operations: operations).load();
      expect(result.failureCategory, BootstrapCacheFailureCategory.sizeLimit);
      expect(operations.readAttempted, isFalse);
      expect(await cacheFile.exists(), isTrue);
    });

    test('rejects malformed UTF-8 strictly', () async {
      await cacheFile.writeAsBytes([0xc3, 0x28]);
      final result = await cache().load();
      expect(result.failureCategory, BootstrapCacheFailureCategory.invalidUtf8);
      expect(result.unusable, isTrue);
      expect(result.document, isNull);
      expect(result.invalidDataRemoved, isFalse);
      expect(await cacheFile.exists(), isTrue);
    });

    for (final entry in {
      'invalid JSON': '{',
      'schema invalid': '{"configVersion":1}',
      'truncated': _validDocument.substring(0, 80),
    }.entries) {
      test('rejects and preserves ${entry.key}', () async {
        await cacheFile.writeAsString(entry.value);
        final result = await cache().load();
        expect(result.success, isFalse);
        expect(result.found, isTrue);
        expect(result.unusable, isTrue);
        expect(result.document, isNull);
        expect(result.parsed!.success, isFalse);
        expect(result.invalidDataRemoved, isFalse);
        expect(await cacheFile.readAsString(), entry.value);
      });
    }
  });

  test('remote fields cannot influence paths or delete arbitrary files',
      () async {
    final traversal = _validDocument.replaceFirst('"first"', '"../../victim"');
    final parsed = await parser.parse(traversal);
    final victim = File(p.join(root.parent.path, 'victim'));
    await victim.writeAsString('safe');
    addTearDown(() async {
      if (await victim.exists()) await victim.delete();
    });

    await cache().saveValidated(document: traversal, parsed: parsed);
    await cache().delete();
    expect(await victim.readAsString(), 'safe');
  });
}

class RecordingOperations extends IoBootstrapCacheFileOperations {
  final bool failWrite;
  final bool failFlush;
  final bool failRename;
  final bool failRead;
  String? writtenPath;
  String? renamedDestination;
  bool readAttempted = false;

  RecordingOperations({
    this.failWrite = false,
    this.failFlush = false,
    this.failRename = false,
    this.failRead = false,
  });

  @override
  Future<Uint8List> readBytes(String path) async {
    readAttempted = true;
    if (failRead) throw StateError('read should not occur');
    return super.readBytes(path);
  }

  @override
  Future<void> writeAndFlush(String path, Uint8List bytes) async {
    writtenPath = path;
    if (failWrite) {
      throw const BootstrapCacheIoException(
          BootstrapCacheFailureCategory.write, 'injected write failure');
    }
    await File(path).writeAsBytes(bytes);
    if (failFlush) {
      throw const BootstrapCacheIoException(
          BootstrapCacheFailureCategory.flush, 'injected flush failure');
    }
  }

  @override
  Future<void> rename(String source, String destination) async {
    renamedDestination = destination;
    if (failRename) {
      throw const BootstrapCacheIoException(
          BootstrapCacheFailureCategory.rename, 'injected rename failure');
    }
    await super.rename(source, destination);
  }
}
