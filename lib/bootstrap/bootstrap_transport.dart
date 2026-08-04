import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const bootstrapTransportConnectionTimeout = Duration(seconds: 5);
const bootstrapTransportOperationTimeout = Duration(seconds: 10);
const bootstrapTransportMaximumBytes = 64 * 1024;
const bootstrapTransportMaximumRedirects = 3;

enum BootstrapDownloadFailure {
  none,
  invalidUri,
  insecureScheme,
  timeout,
  dns,
  connection,
  tls,
  redirect,
  httpStatus,
  sizeLimit,
  invalidUtf8,
  malformedResponse,
  cancelled,
  unknown,
}

class BootstrapDownloadResult {
  final Uri requestedUri;
  final Uri? effectiveUri;
  final bool success;
  final Uint8List? responseBytes;
  final String? responseText;
  final int? httpStatusCode;
  final int? contentLength;
  final int elapsedMilliseconds;
  final int? redirectCount;
  final BootstrapDownloadFailure failureCategory;
  final String diagnosticMessage;

  const BootstrapDownloadResult({
    required this.requestedUri,
    required this.effectiveUri,
    required this.success,
    required this.responseBytes,
    required this.responseText,
    required this.httpStatusCode,
    required this.contentLength,
    required this.elapsedMilliseconds,
    required this.redirectCount,
    required this.failureCategory,
    required this.diagnosticMessage,
  });
}

class BootstrapHttpResponse {
  final int statusCode;
  final int? contentLength;
  final String? location;
  final Stream<List<int>> body;
  final FutureOr<void> Function() close;

  const BootstrapHttpResponse({
    required this.statusCode,
    required this.contentLength,
    required this.location,
    required this.body,
    required this.close,
  });
}

abstract class BootstrapRequestExecutor {
  Future<BootstrapHttpResponse> get(
    Uri uri, {
    required Duration connectionTimeout,
    required Map<String, String> headers,
  });
}

class IoBootstrapRequestExecutor implements BootstrapRequestExecutor {
  const IoBootstrapRequestExecutor();

  @override
  Future<BootstrapHttpResponse> get(
    Uri uri, {
    required Duration connectionTimeout,
    required Map<String, String> headers,
  }) async {
    final client = HttpClient()..connectionTimeout = connectionTimeout;
    try {
      final request = await client.getUrl(uri);
      request.followRedirects = false;
      headers.forEach(request.headers.set);
      final response = await request.close();
      return BootstrapHttpResponse(
        statusCode: response.statusCode,
        contentLength:
            response.contentLength < 0 ? null : response.contentLength,
        location: response.headers.value(HttpHeaders.locationHeader),
        body: response.transform(
          StreamTransformer<List<int>, List<int>>.fromHandlers(
            handleDone: (sink) {
              client.close(force: true);
              sink.close();
            },
            handleError: (error, stackTrace, sink) {
              client.close(force: true);
              sink.addError(error, stackTrace);
            },
          ),
        ),
        close: () => client.close(force: true),
      );
    } catch (_) {
      client.close(force: true);
      rethrow;
    }
  }
}

typedef BootstrapElapsedMilliseconds = int Function();

/// Downloads bytes over HTTPS without interpreting the bootstrap schema.
///
/// Query parameters are allowed for hosted URLs, but diagnostics expose only
/// the host so deployment tokens are not disclosed. Transport success does not
/// make a document trusted: Stage 5B will add schema and BUCK-network checks,
/// Last-Known-Good persistence is deferred, and signature verification remains
/// a later stage. Hosting, DNS, repository-account, or trusted-CA compromise is
/// outside the protections provided here.
class BootstrapTransport {
  static const _headers = <String, String>{
    HttpHeaders.acceptHeader: 'application/json',
  };

  final BootstrapRequestExecutor requestExecutor;
  final Duration connectionTimeout;
  final Duration operationTimeout;
  final int maximumBytes;
  final int maximumRedirects;
  final BootstrapElapsedMilliseconds? elapsedMilliseconds;

  const BootstrapTransport({
    this.requestExecutor = const IoBootstrapRequestExecutor(),
    this.connectionTimeout = bootstrapTransportConnectionTimeout,
    this.operationTimeout = bootstrapTransportOperationTimeout,
    this.maximumBytes = bootstrapTransportMaximumBytes,
    this.maximumRedirects = bootstrapTransportMaximumRedirects,
    this.elapsedMilliseconds,
  });

  Future<BootstrapDownloadResult> download(Uri uri) async {
    final stopwatch =
        elapsedMilliseconds == null ? (Stopwatch()..start()) : null;
    final start = elapsedMilliseconds?.call() ?? 0;
    int elapsed() =>
        elapsedMilliseconds?.call() ?? stopwatch!.elapsedMilliseconds;

    BootstrapDownloadResult failure(
      BootstrapDownloadFailure category,
      String message, {
      Uri? effectiveUri,
      int? status,
      int? length,
      int? redirects,
    }) =>
        BootstrapDownloadResult(
          requestedUri: uri,
          effectiveUri: effectiveUri,
          success: false,
          responseBytes: null,
          responseText: null,
          httpStatusCode: status,
          contentLength: length,
          elapsedMilliseconds: elapsed() - start,
          redirectCount: redirects,
          failureCategory: category,
          diagnosticMessage: message,
        );

    final validation = _validateUri(uri);
    if (validation != null) {
      return failure(validation.$1, validation.$2, redirects: 0);
    }

    FutureOr<void> Function()? closeActiveResponse;
    try {
      return await _download(
        uri,
        elapsed,
        start,
        (close) => closeActiveResponse = close,
      ).timeout(operationTimeout);
    } on TimeoutException {
      await closeActiveResponse?.call();
      return failure(
        BootstrapDownloadFailure.timeout,
        'HTTPS download from ${uri.host} exceeded '
        '${operationTimeout.inMilliseconds} ms',
      );
    } on HandshakeException {
      return failure(BootstrapDownloadFailure.tls,
          'TLS negotiation with ${uri.host} failed');
    } on SocketException catch (error) {
      final category = _socketFailure(error);
      return failure(category, '${category.name} failure for ${uri.host}');
    } on HttpException {
      return failure(BootstrapDownloadFailure.malformedResponse,
          'Malformed HTTP response from ${uri.host}');
    } on BootstrapRequestCancelledException {
      return failure(BootstrapDownloadFailure.cancelled,
          'HTTPS download from ${uri.host} was cancelled');
    } catch (_) {
      return failure(BootstrapDownloadFailure.unknown,
          'Unknown HTTPS transport failure for ${uri.host}');
    } finally {
      stopwatch?.stop();
    }
  }

  Future<BootstrapDownloadResult> _download(
    Uri requested,
    int Function() elapsed,
    int start,
    void Function(FutureOr<void> Function() close) onResponse,
  ) async {
    var current = requested;
    var redirects = 0;
    final visited = <String>{requested.toString()};

    while (true) {
      final response = await requestExecutor.get(
        current,
        connectionTimeout: connectionTimeout,
        headers: _headers,
      );
      onResponse(response.close);
      try {
        final status = response.statusCode;
        if (_isRedirect(status)) {
          final location = response.location;
          if (location == null || location.trim().isEmpty) {
            return _resultFailure(requested, current, elapsed() - start, status,
                response.contentLength, redirects, 'Redirect has no Location');
          }
          if (redirects >= maximumRedirects) {
            return _resultFailure(requested, current, elapsed() - start, status,
                response.contentLength, redirects, 'Redirect limit exceeded');
          }
          Uri target;
          try {
            target = current.resolve(location);
          } on FormatException {
            return _resultFailure(
                requested,
                current,
                elapsed() - start,
                status,
                response.contentLength,
                redirects,
                'Malformed redirect Location');
          }
          final targetValidation = _validateUri(target);
          if (targetValidation != null) {
            return _resultFailure(requested, current, elapsed() - start, status,
                response.contentLength, redirects, 'Unsafe redirect target');
          }
          if (!visited.add(target.toString())) {
            return _resultFailure(requested, current, elapsed() - start, status,
                response.contentLength, redirects, 'Redirect loop detected');
          }
          redirects++;
          current = target;
          continue;
        }
        if (status != HttpStatus.ok) {
          return BootstrapDownloadResult(
            requestedUri: requested,
            effectiveUri: current,
            success: false,
            responseBytes: null,
            responseText: null,
            httpStatusCode: status,
            contentLength: response.contentLength,
            elapsedMilliseconds: elapsed() - start,
            redirectCount: redirects,
            failureCategory: BootstrapDownloadFailure.httpStatus,
            diagnosticMessage: 'HTTP status $status from ${current.host}',
          );
        }
        if (response.contentLength != null &&
            response.contentLength! > maximumBytes) {
          return BootstrapDownloadResult(
            requestedUri: requested,
            effectiveUri: current,
            success: false,
            responseBytes: null,
            responseText: null,
            httpStatusCode: status,
            contentLength: response.contentLength,
            elapsedMilliseconds: elapsed() - start,
            redirectCount: redirects,
            failureCategory: BootstrapDownloadFailure.sizeLimit,
            diagnosticMessage:
                'Response from ${current.host} exceeds $maximumBytes bytes',
          );
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response.body) {
          if (bytes.length + chunk.length > maximumBytes) {
            return BootstrapDownloadResult(
              requestedUri: requested,
              effectiveUri: current,
              success: false,
              responseBytes: null,
              responseText: null,
              httpStatusCode: status,
              contentLength: bytes.length + chunk.length,
              elapsedMilliseconds: elapsed() - start,
              redirectCount: redirects,
              failureCategory: BootstrapDownloadFailure.sizeLimit,
              diagnosticMessage:
                  'Streamed response from ${current.host} exceeds $maximumBytes bytes',
            );
          }
          bytes.add(chunk);
        }
        final body = bytes.takeBytes();
        String text;
        try {
          text = utf8.decode(body, allowMalformed: false);
        } on FormatException {
          return BootstrapDownloadResult(
            requestedUri: requested,
            effectiveUri: current,
            success: false,
            responseBytes: null,
            responseText: null,
            httpStatusCode: status,
            contentLength: body.length,
            elapsedMilliseconds: elapsed() - start,
            redirectCount: redirects,
            failureCategory: BootstrapDownloadFailure.invalidUtf8,
            diagnosticMessage:
                'Response from ${current.host} is not valid UTF-8',
          );
        }
        return BootstrapDownloadResult(
          requestedUri: requested,
          effectiveUri: current,
          success: true,
          responseBytes: body,
          responseText: text,
          httpStatusCode: status,
          contentLength: body.length,
          elapsedMilliseconds: elapsed() - start,
          redirectCount: redirects,
          failureCategory: BootstrapDownloadFailure.none,
          diagnosticMessage:
              'Downloaded ${body.length} bytes from ${current.host}',
        );
      } finally {
        await response.close();
      }
    }
  }

  static BootstrapDownloadResult _resultFailure(
          Uri requested,
          Uri effective,
          int elapsed,
          int status,
          int? length,
          int redirects,
          String message) =>
      BootstrapDownloadResult(
        requestedUri: requested,
        effectiveUri: effective,
        success: false,
        responseBytes: null,
        responseText: null,
        httpStatusCode: status,
        contentLength: length,
        elapsedMilliseconds: elapsed,
        redirectCount: redirects,
        failureCategory: BootstrapDownloadFailure.redirect,
        diagnosticMessage: message,
      );

  static (BootstrapDownloadFailure, String)? _validateUri(Uri uri) {
    if (!uri.isAbsolute) {
      return (
        BootstrapDownloadFailure.invalidUri,
        'Bootstrap URI is not absolute'
      );
    }
    if (uri.scheme.toLowerCase() != 'https') {
      return (
        BootstrapDownloadFailure.insecureScheme,
        'Bootstrap URI must use HTTPS'
      );
    }
    if (uri.host.isEmpty) {
      return (BootstrapDownloadFailure.invalidUri, 'Bootstrap URI has no host');
    }
    if (uri.userInfo.isNotEmpty) {
      return (
        BootstrapDownloadFailure.invalidUri,
        'Bootstrap URI contains credentials'
      );
    }
    if (uri.hasFragment) {
      return (
        BootstrapDownloadFailure.invalidUri,
        'Bootstrap URI contains a fragment'
      );
    }
    if (uri.hasPort && uri.port != 443) {
      return (
        BootstrapDownloadFailure.invalidUri,
        'Bootstrap URI uses an unsupported port'
      );
    }
    return null;
  }

  static bool _isRedirect(int status) =>
      status == 301 ||
      status == 302 ||
      status == 303 ||
      status == 307 ||
      status == 308;

  static BootstrapDownloadFailure _socketFailure(SocketException error) {
    final message = error.message.toLowerCase();
    if (message.contains('failed host lookup') ||
        message.contains('name or service not known') ||
        message.contains('nodename nor servname')) {
      return BootstrapDownloadFailure.dns;
    }
    if (message.contains('refused')) return BootstrapDownloadFailure.connection;
    return BootstrapDownloadFailure.unknown;
  }
}

class BootstrapRequestCancelledException implements Exception {
  const BootstrapRequestCancelledException();
}
