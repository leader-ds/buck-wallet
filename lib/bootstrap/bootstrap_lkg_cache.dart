import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'bootstrap_lkg_cache_models.dart';
import 'bootstrap_parser.dart';

export 'bootstrap_lkg_cache_models.dart';

const bootstrapLkgCacheFilename = 'buck_bootstrap_lkg_v1.json';
const bootstrapLkgCacheTemporaryFilename = 'buck_bootstrap_lkg_v1.json.tmp';
const bootstrapLkgCacheMaximumBytes = 64 * 1024;

typedef BootstrapCacheDirectoryProvider = Future<Directory> Function();
typedef BootstrapCacheElapsedMilliseconds = int Function();

abstract class BootstrapCache {
  Future<BootstrapCacheLoadResult> load();

  Future<BootstrapCacheSaveResult> saveValidated({
    required String document,
    required BootstrapParseResult parsed,
  });

  Future<BootstrapCacheDeleteResult> delete();
}

/// A structurally Last-Known-Good cache, not a trust boundary.
///
/// Every load is reparsed with [BootstrapParser]. Cache presence does not make
/// content authentic; signature verification remains Stage 6. Later source
/// orchestration must retain the embedded FR1/FR2 availability fallback.
class FileBootstrapCache implements BootstrapCache {
  final BootstrapCacheDirectoryProvider directoryProvider;
  final BootstrapParser parser;
  final BootstrapCacheFileOperations fileOperations;
  final BootstrapCacheElapsedMilliseconds? elapsedMilliseconds;

  FileBootstrapCache({
    BootstrapCacheDirectoryProvider? directoryProvider,
    this.parser = const BootstrapParser(),
    this.fileOperations = const IoBootstrapCacheFileOperations(),
    this.elapsedMilliseconds,
  }) : directoryProvider = directoryProvider ?? getApplicationSupportDirectory;

  @override
  Future<BootstrapCacheLoadResult> load() async {
    final timing = _Timing(elapsedMilliseconds);
    try {
      final paths = await _paths();
      if (!await fileOperations.exists(paths.finalPath)) {
        return _loadResult(
          timing,
          success: true,
          found: false,
          failure: BootstrapCacheFailureCategory.notFound,
          message: 'Bootstrap cache is not present.',
        );
      }
      final length = await fileOperations.length(paths.finalPath);
      if (length > bootstrapLkgCacheMaximumBytes) {
        return _loadResult(
          timing,
          success: false,
          found: true,
          failure: BootstrapCacheFailureCategory.sizeLimit,
          message: 'Bootstrap cache exceeds the 65536-byte limit.',
          byteCount: length,
          unusable: true,
        );
      }
      final bytes = await fileOperations.readBytes(paths.finalPath);
      if (bytes.length > bootstrapLkgCacheMaximumBytes) {
        return _loadResult(
          timing,
          success: false,
          found: true,
          failure: BootstrapCacheFailureCategory.sizeLimit,
          message: 'Bootstrap cache exceeds the 65536-byte limit.',
          byteCount: bytes.length,
          unusable: true,
        );
      }
      String document;
      try {
        document = utf8.decode(bytes, allowMalformed: false);
      } on FormatException {
        return _loadResult(
          timing,
          success: false,
          found: true,
          failure: BootstrapCacheFailureCategory.invalidUtf8,
          message: 'Bootstrap cache is not valid UTF-8.',
          byteCount: bytes.length,
          unusable: true,
        );
      }
      final parsed = await parser.parse(document);
      if (!parsed.success) {
        return _loadResult(
          timing,
          success: false,
          found: true,
          failure: BootstrapCacheFailureCategory.invalidDocument,
          message: 'Bootstrap cache failed schema validation.',
          byteCount: bytes.length,
          parsed: parsed,
          unusable: true,
        );
      }
      return _loadResult(
        timing,
        success: true,
        found: true,
        failure: BootstrapCacheFailureCategory.none,
        message: 'Bootstrap cache loaded and revalidated.',
        byteCount: bytes.length,
        document: document,
        parsed: parsed,
      );
    } on BootstrapCacheIoException catch (error) {
      return _loadResult(timing,
          success: false,
          found: error.found,
          failure: error.category,
          message: error.message,
          unusable: error.found);
    } on FileSystemException catch (error) {
      return _loadResult(timing,
          success: false,
          found: false,
          failure: _fileFailure(error, BootstrapCacheFailureCategory.read),
          message: 'Bootstrap cache could not be read.');
    } catch (_) {
      return _loadResult(timing,
          success: false,
          found: false,
          failure: BootstrapCacheFailureCategory.unavailable,
          message: 'Bootstrap cache location is unavailable.');
    } finally {
      timing.stop();
    }
  }

  @override
  Future<BootstrapCacheSaveResult> saveValidated({
    required String document,
    required BootstrapParseResult parsed,
  }) async {
    final timing = _Timing(elapsedMilliseconds);
    final bytes = Uint8List.fromList(utf8.encode(document));
    BootstrapCacheSaveResult failure(
            BootstrapCacheFailureCategory category, String message) =>
        BootstrapCacheSaveResult(
          success: false,
          byteCount: bytes.length,
          elapsedMilliseconds: timing.elapsed,
          failureCategory: category,
          diagnosticMessage: message,
          cacheKey: bootstrapLkgCacheFilename,
          atomicReplacementCompleted: false,
        );
    try {
      if (bytes.length > bootstrapLkgCacheMaximumBytes) {
        return failure(BootstrapCacheFailureCategory.sizeLimit,
            'Bootstrap document exceeds the 65536-byte limit.');
      }
      if (!parsed.success) {
        return failure(BootstrapCacheFailureCategory.invalidDocument,
            'Only a successfully parsed bootstrap document may be cached.');
      }
      final fresh = await parser.parse(document);
      if (!fresh.success) {
        return failure(BootstrapCacheFailureCategory.invalidDocument,
            'Bootstrap document failed internal schema validation.');
      }
      if (!_equivalent(parsed, fresh)) {
        return failure(BootstrapCacheFailureCategory.invalidDocument,
            'Bootstrap document does not match its supplied parse result.');
      }

      final paths = await _paths();
      await fileOperations.ensureDirectory(paths.directory);
      await _deleteIfPresent(paths.temporaryPath);
      try {
        await fileOperations.writeAndFlush(paths.temporaryPath, bytes);
        await fileOperations.rename(paths.temporaryPath, paths.finalPath);
      } on BootstrapCacheIoException catch (error) {
        await _cleanupTemporary(paths.temporaryPath);
        return failure(error.category, error.message);
      } on FileSystemException catch (error) {
        await _cleanupTemporary(paths.temporaryPath);
        return failure(
            _fileFailure(error, BootstrapCacheFailureCategory.rename),
            'Atomic bootstrap cache replacement failed.');
      }
      return BootstrapCacheSaveResult(
        success: true,
        byteCount: bytes.length,
        elapsedMilliseconds: timing.elapsed,
        failureCategory: BootstrapCacheFailureCategory.none,
        diagnosticMessage: 'Bootstrap cache atomically replaced.',
        cacheKey: bootstrapLkgCacheFilename,
        atomicReplacementCompleted: true,
      );
    } on FileSystemException catch (error) {
      return failure(_fileFailure(error, BootstrapCacheFailureCategory.write),
          'Bootstrap cache could not be written.');
    } catch (_) {
      return failure(BootstrapCacheFailureCategory.unavailable,
          'Bootstrap cache location is unavailable.');
    } finally {
      timing.stop();
    }
  }

  @override
  Future<BootstrapCacheDeleteResult> delete() async {
    try {
      final paths = await _paths();
      final existed = await fileOperations.exists(paths.finalPath);
      if (existed) await fileOperations.delete(paths.finalPath);
      await _deleteIfPresent(paths.temporaryPath);
      return BootstrapCacheDeleteResult(
        success: true,
        existed: existed,
        failureCategory: BootstrapCacheFailureCategory.none,
        diagnosticMessage: existed
            ? 'Bootstrap cache deleted.'
            : 'Bootstrap cache was already absent.',
      );
    } on FileSystemException catch (error) {
      return BootstrapCacheDeleteResult(
        success: false,
        existed: true,
        failureCategory:
            _fileFailure(error, BootstrapCacheFailureCategory.delete),
        diagnosticMessage: 'Bootstrap cache could not be deleted.',
      );
    } catch (_) {
      return const BootstrapCacheDeleteResult(
        success: false,
        existed: false,
        failureCategory: BootstrapCacheFailureCategory.unavailable,
        diagnosticMessage: 'Bootstrap cache location is unavailable.',
      );
    }
  }

  Future<_CachePaths> _paths() async {
    final directory = await directoryProvider();
    return _CachePaths(
      directory,
      p.join(directory.path, bootstrapLkgCacheFilename),
      p.join(directory.path, bootstrapLkgCacheTemporaryFilename),
    );
  }

  Future<void> _deleteIfPresent(String path) async {
    if (await fileOperations.exists(path)) await fileOperations.delete(path);
  }

  Future<void> _cleanupTemporary(String path) async {
    try {
      await _deleteIfPresent(path);
    } catch (_) {
      // Best-effort cleanup must not hide the original write failure.
    }
  }
}

abstract class BootstrapCacheFileOperations {
  const BootstrapCacheFileOperations();

  Future<bool> exists(String path);
  Future<int> length(String path);
  Future<Uint8List> readBytes(String path);
  Future<void> ensureDirectory(Directory directory);
  Future<void> writeAndFlush(String path, Uint8List bytes);
  Future<void> rename(String source, String destination);
  Future<void> delete(String path);
}

class IoBootstrapCacheFileOperations extends BootstrapCacheFileOperations {
  const IoBootstrapCacheFileOperations();

  @override
  Future<bool> exists(String path) => File(path).exists();

  @override
  Future<int> length(String path) => File(path).length();

  @override
  Future<Uint8List> readBytes(String path) => File(path).readAsBytes();

  @override
  Future<void> ensureDirectory(Directory directory) =>
      directory.create(recursive: true);

  @override
  Future<void> writeAndFlush(String path, Uint8List bytes) async {
    late RandomAccessFile output;
    try {
      output = await File(path).open(mode: FileMode.write);
    } on FileSystemException catch (error) {
      throw BootstrapCacheIoException(
          _fileFailure(error, BootstrapCacheFailureCategory.write),
          'Temporary bootstrap cache write failed.');
    }
    try {
      try {
        await output.writeFrom(bytes);
      } on FileSystemException catch (error) {
        throw BootstrapCacheIoException(
            _fileFailure(error, BootstrapCacheFailureCategory.write),
            'Temporary bootstrap cache write failed.');
      }
      try {
        await output.flush();
      } on FileSystemException catch (error) {
        throw BootstrapCacheIoException(
            _fileFailure(error, BootstrapCacheFailureCategory.flush),
            'Temporary bootstrap cache flush failed.');
      }
    } finally {
      await output.close();
    }
  }

  @override
  Future<void> rename(String source, String destination) async {
    try {
      await File(source).rename(destination);
    } on FileSystemException catch (error) {
      throw BootstrapCacheIoException(
          _fileFailure(error, BootstrapCacheFailureCategory.rename),
          'Atomic bootstrap cache replacement failed.');
    }
  }

  @override
  Future<void> delete(String path) => File(path).delete();
}

class BootstrapCacheIoException implements Exception {
  final BootstrapCacheFailureCategory category;
  final String message;
  final bool found;

  const BootstrapCacheIoException(this.category, this.message,
      {this.found = false});
}

bool _equivalent(BootstrapParseResult left, BootstrapParseResult right) {
  if (left.configVersion != right.configVersion ||
      left.network != right.network ||
      left.servers.length != right.servers.length) return false;
  for (var i = 0; i < left.servers.length; i++) {
    final a = left.servers[i];
    final b = right.servers[i];
    if (a.id != b.id ||
        a.grpcUrl != b.grpcUrl ||
        a.priority != b.priority ||
        a.enabled != b.enabled) return false;
  }
  return true;
}

BootstrapCacheFailureCategory _fileFailure(
    FileSystemException error, BootstrapCacheFailureCategory fallback) {
  final message = error.message.toLowerCase();
  if (message.contains('permission') ||
      message.contains('access is denied') ||
      error.osError?.errorCode == 5 ||
      error.osError?.errorCode == 13) {
    return BootstrapCacheFailureCategory.permission;
  }
  return fallback;
}

BootstrapCacheLoadResult _loadResult(
  _Timing timing, {
  required bool success,
  required bool found,
  required BootstrapCacheFailureCategory failure,
  required String message,
  String? document,
  BootstrapParseResult? parsed,
  int? byteCount,
  bool unusable = false,
}) =>
    BootstrapCacheLoadResult(
      success: success,
      found: found,
      document: document,
      parsed: parsed,
      failureCategory: failure,
      diagnosticMessage: message,
      cacheKey: bootstrapLkgCacheFilename,
      byteCount: byteCount,
      elapsedMilliseconds: timing.elapsed,
      unusable: unusable,
      invalidDataRemoved: false,
    );

class _CachePaths {
  final Directory directory;
  final String finalPath;
  final String temporaryPath;
  const _CachePaths(this.directory, this.finalPath, this.temporaryPath);
}

class _Timing {
  final BootstrapCacheElapsedMilliseconds? source;
  final Stopwatch? stopwatch;
  final int start;

  _Timing(this.source)
      : stopwatch = source == null ? (Stopwatch()..start()) : null,
        start = source?.call() ?? 0;

  int get elapsed =>
      source == null ? stopwatch!.elapsedMilliseconds : source!.call() - start;
  void stop() => stopwatch?.stop();
}
