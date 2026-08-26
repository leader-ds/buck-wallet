import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:buck_wallet/bootstrap/bootstrap_transport.dart';
import 'package:flutter_test/flutter_test.dart';

class RecordedRequest {
  final Uri uri;
  final Map<String, String> headers;
  final Duration connectionTimeout;
  const RecordedRequest(this.uri, this.headers, this.connectionTimeout);
}

class FakeExecutor implements BootstrapRequestExecutor {
  final List<Object> responses;
  final requests = <RecordedRequest>[];
  FakeExecutor(Object response) : responses = [response];
  FakeExecutor.sequence(this.responses);

  @override
  Future<BootstrapHttpResponse> get(Uri uri,
      {required Duration connectionTimeout,
      required Map<String, String> headers}) async {
    requests.add(RecordedRequest(uri, Map.of(headers), connectionTimeout));
    final response = responses.removeAt(0);
    if (response is Exception) throw response;
    if (response is Future<BootstrapHttpResponse>) return response;
    return response as BootstrapHttpResponse;
  }
}

BootstrapHttpResponse response(int status, List<int> bytes,
        {int? contentLength, String? location, void Function()? onListen}) =>
    BootstrapHttpResponse(
      statusCode: status,
      contentLength: contentLength,
      location: location,
      close: () {},
      body: Stream<List<int>>.multi((controller) {
        onListen?.call();
        controller.add(bytes);
        controller.close();
      }),
    );

void main() {
  final uri = Uri.parse('https://config.example/bootstrap.json');
  var tick = 100;

  BootstrapTransport transport(FakeExecutor executor,
          {int maximumRedirects = bootstrapTransportMaximumRedirects}) =>
      BootstrapTransport(
        requestExecutor: executor,
        maximumRedirects: maximumRedirects,
        elapsedMilliseconds: () => tick++,
      );

  group('URI validation and query policy', () {
    for (final entry in <String, BootstrapDownloadFailure>{
      'http://config.example/x': BootstrapDownloadFailure.insecureScheme,
      'bootstrap.json': BootstrapDownloadFailure.invalidUri,
      'https:///bootstrap.json': BootstrapDownloadFailure.invalidUri,
      'https://user:password@config.example/x':
          BootstrapDownloadFailure.invalidUri,
      'https://config.example/x#fragment': BootstrapDownloadFailure.invalidUri,
      'https://config.example:9067/x': BootstrapDownloadFailure.invalidUri,
    }.entries) {
      test('rejects ${entry.key} before request execution', () async {
        final fake = FakeExecutor(response(200, []));
        final result = await transport(fake).download(Uri.parse(entry.key));
        expect(result.failureCategory, entry.value);
        expect(fake.requests, isEmpty);
      });
    }

    test('accepts HTTPS URI and preserves allowed query', () async {
      final fake = FakeExecutor(response(200, utf8.encode('ok')));
      final queried = Uri.parse('HTTPS://config.example/x?token=deployment');
      final result = await transport(fake).download(queried);
      expect(result.success, isTrue);
      expect(fake.requests.single.uri.query, 'token=deployment');
      expect(result.diagnosticMessage, isNot(contains('deployment')));
    });
  });

  group('successful response and size limits', () {
    test('preserves text, bytes, status, length, URI, redirects, and elapsed',
        () async {
      final fake = FakeExecutor(response(200, utf8.encode('hello')));
      final result = await transport(fake).download(uri);
      expect(result.success, isTrue);
      expect(result.responseText, 'hello');
      expect(result.responseBytes, utf8.encode('hello'));
      expect(result.httpStatusCode, 200);
      expect(result.contentLength, 5);
      expect(result.requestedUri, uri);
      expect(result.effectiveUri, uri);
      expect(result.redirectCount, 0);
      expect(result.elapsedMilliseconds, greaterThanOrEqualTo(0));
      expect(result.failureCategory, BootstrapDownloadFailure.none);
    });

    test('missing Content-Length succeeds', () async {
      final result = await transport(FakeExecutor(
              response(200, utf8.encode('{}'), contentLength: null)))
          .download(uri);
      expect(result.success, isTrue);
      expect(result.contentLength, 2);
    });

    test('exactly 64 KiB succeeds', () async {
      final bytes = List<int>.filled(bootstrapTransportMaximumBytes, 0x61);
      final result =
          await transport(FakeExecutor(response(200, bytes))).download(uri);
      expect(result.success, isTrue);
      expect(result.contentLength, bootstrapTransportMaximumBytes);
    });

    test('oversized Content-Length rejects before listening to body', () async {
      var listened = false;
      final fake = FakeExecutor(response(200, const [],
          contentLength: bootstrapTransportMaximumBytes + 1,
          onListen: () => listened = true));
      final result = await transport(fake).download(uri);
      expect(result.failureCategory, BootstrapDownloadFailure.sizeLimit);
      expect(listened, isFalse);
    });

    for (final extra in [1, 20]) {
      test(
          'streamed body ${extra == 1 ? 'one byte' : 'well'} over limit rejects',
          () async {
        final bytes =
            List<int>.filled(bootstrapTransportMaximumBytes + extra, 0x61);
        final result =
            await transport(FakeExecutor(response(200, bytes))).download(uri);
        expect(result.failureCategory, BootstrapDownloadFailure.sizeLimit);
      });
    }
  });

  group('UTF-8 and status policy', () {
    test('malformed UTF-8 is typed invalidUtf8', () async {
      final result =
          await transport(FakeExecutor(response(200, [0xff]))).download(uri);
      expect(result.failureCategory, BootstrapDownloadFailure.invalidUtf8);
    });

    test('malformed JSON in valid UTF-8 remains transport success', () async {
      final result =
          await transport(FakeExecutor(response(200, utf8.encode('{'))))
              .download(uri);
      expect(result.success, isTrue);
      expect(result.responseText, '{');
    });

    for (final status in [201, 204, 206, 404, 500]) {
      test('HTTP $status is typed httpStatus', () async {
        final result = await transport(FakeExecutor(response(status, const [])))
            .download(uri);
        expect(result.failureCategory, BootstrapDownloadFailure.httpStatus);
        expect(result.httpStatusCode, status);
      });
    }
  });

  group('redirect policy', () {
    test('HTTPS redirect succeeds and reports final URI/count', () async {
      final fake = FakeExecutor.sequence([
        response(302, const [], location: '/next'),
        response(200, utf8.encode('ok')),
      ]);
      final result = await transport(fake).download(uri);
      expect(result.success, isTrue);
      expect(result.effectiveUri, Uri.parse('https://config.example/next'));
      expect(result.redirectCount, 1);
    });

    for (final location in <String?>[null, '', 'http://evil.example/x']) {
      test('rejects redirect Location ${location ?? 'missing'}', () async {
        final result = await transport(
                FakeExecutor(response(302, const [], location: location)))
            .download(uri);
        expect(result.failureCategory, BootstrapDownloadFailure.redirect);
      });
    }

    test('rejects malformed redirect Location', () async {
      final result = await transport(
              FakeExecutor(response(302, const [], location: 'https://[bad')))
          .download(uri);
      expect(result.failureCategory, BootstrapDownloadFailure.redirect);
    });

    test('rejects redirect loop', () async {
      final fake = FakeExecutor.sequence([
        response(302, const [], location: '/next'),
        response(302, const [], location: '/bootstrap.json'),
      ]);
      final result = await transport(fake).download(uri);
      expect(result.failureCategory, BootstrapDownloadFailure.redirect);
    });

    test('rejects redirect count over limit', () async {
      final fake = FakeExecutor.sequence([
        response(302, const [], location: '/one'),
        response(302, const [], location: '/two'),
      ]);
      final result = await transport(fake, maximumRedirects: 1).download(uri);
      expect(result.failureCategory, BootstrapDownloadFailure.redirect);
      expect(fake.requests, hasLength(2));
    });
  });

  group('timeouts and network classification', () {
    test('total timeout is typed timeout', () async {
      final pending = Completer<BootstrapHttpResponse>();
      final result = await BootstrapTransport(
        requestExecutor: FakeExecutor(pending.future),
        operationTimeout: const Duration(milliseconds: 1),
      ).download(uri);
      expect(result.failureCategory, BootstrapDownloadFailure.timeout);
    });

    test('supported DNS failure is typed dns', () async {
      final result = await transport(
              FakeExecutor(const SocketException('Failed host lookup')))
          .download(uri);
      expect(result.failureCategory, BootstrapDownloadFailure.dns);
    });

    test('supported connection refusal is typed connection', () async {
      final result = await transport(
              FakeExecutor(const SocketException('Connection refused')))
          .download(uri);
      expect(result.failureCategory, BootstrapDownloadFailure.connection);
    });

    test('TLS failure is typed tls', () async {
      final result = await transport(
              FakeExecutor(const HandshakeException('certificate failure')))
          .download(uri);
      expect(result.failureCategory, BootstrapDownloadFailure.tls);
    });

    test('unsupported socket detail and arbitrary exception are unknown',
        () async {
      var result = await transport(FakeExecutor(const SocketException('other')))
          .download(uri);
      expect(result.failureCategory, BootstrapDownloadFailure.unknown);
      result =
          await transport(FakeExecutor(Exception('surprise'))).download(uri);
      expect(result.failureCategory, BootstrapDownloadFailure.unknown);
    });

    test('explicit executor cancellation is typed cancelled', () async {
      final result = await transport(
              FakeExecutor(const BootstrapRequestCancelledException()))
          .download(uri);
      expect(result.failureCategory, BootstrapDownloadFailure.cancelled);
    });
  });

  test('request is GET-only executor input with minimal privacy-safe headers',
      () async {
    final fake = FakeExecutor(response(200, utf8.encode('{}')));
    await transport(fake).download(uri);
    final request = fake.requests.single;
    expect(request.headers, {HttpHeaders.acceptHeader: 'application/json'});
    expect(request.connectionTimeout, bootstrapTransportConnectionTimeout);
    final serialized = request.headers.toString().toLowerCase();
    for (final forbidden in [
      'account',
      'address',
      'wallet',
      'seed',
      'device',
      'authorization',
      'cookie'
    ]) {
      expect(serialized, isNot(contains(forbidden)));
    }
  });

  test('redirect requests retain only the same minimal safe header', () async {
    final fake = FakeExecutor.sequence([
      response(302, const [], location: 'https://cdn.example/config'),
      response(200, utf8.encode('{}')),
    ]);
    await transport(fake).download(uri);
    expect(fake.requests, hasLength(2));
    expect(fake.requests[1].headers,
        {HttpHeaders.acceptHeader: 'application/json'});
  });
}
