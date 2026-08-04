import 'dart:convert';

import 'package:YWallet/bootstrap/bootstrap_parser.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> server({
  String id = 'primary',
  String displayName = 'Primary',
  String grpcUrl = 'https://wallet.buck.red:9067',
  int priority = 10,
  bool enabled = true,
}) =>
    {
      'id': id,
      'displayName': displayName,
      'grpcUrl': grpcUrl,
      'priority': priority,
      'enabled': enabled,
    };

Map<String, dynamic> document({List<Map<String, dynamic>>? servers}) => {
      'configVersion': 1,
      'network': 'BUCK',
      'servers': servers ?? [server()],
    };

Future<BootstrapParseResult> parse(Object? value) =>
    const BootstrapParser().parse(jsonEncode(value));

void main() {
  group('valid documents', () {
    test('parses a minimal valid document into immutable values', () async {
      final result = await parse(document());

      expect(result.success, isTrue);
      expect(result.configVersion, 1);
      expect(result.network, 'BUCK');
      expect(result.servers.single.id, 'primary');
      expect(result.validationErrors, isEmpty);
      expect(() => result.servers.add(result.servers.single),
          throwsUnsupportedError);
    });

    test('parses multiple servers and sorts stably by priority', () async {
      final result = await parse(document(servers: [
        server(id: 'late', priority: 20),
        server(id: 'first-tie', grpcUrl: 'https://one.example', priority: 5),
        server(id: 'second-tie', grpcUrl: 'https://two.example', priority: 5),
      ]));

      expect(result.success, isTrue);
      expect(result.servers.map((value) => value.id),
          ['first-tie', 'second-tie', 'late']);
    });

    test('ignores and counts unknown top-level and server fields', () async {
      final value = document()
        ..['futureTopLevel'] = true
        ..['anotherFutureField'] = 7;
      (value['servers'] as List).single['futureServerField'] = 'ignored';

      final result = await parse(value);

      expect(result.success, isTrue);
      expect(result.unknownFieldCount, 3);
    });
  });

  group('document failures', () {
    test('rejects invalid JSON without exposing an exception', () async {
      final result = await const BootstrapParser().parse('{');
      expect(result.success, isFalse);
      expect(result.validationErrors.single.category,
          BootstrapParseFailureCategory.invalidJson);
      expect(result.validationErrors.single.message,
          isNot(contains('at character')));
    });

    test('rejects missing configVersion', () async {
      final value = document()..remove('configVersion');
      expect((await parse(value)).validationErrors.single.category,
          BootstrapParseFailureCategory.missingField);
    });

    for (final value in <Object?>['1', 1.0, null]) {
      test('rejects wrong configVersion value $value', () async {
        final input = document()..['configVersion'] = value;
        expect((await parse(input)).success, isFalse);
      });
    }

    test('rejects negative configVersion', () async {
      final value = document()..['configVersion'] = -1;
      expect((await parse(value)).validationErrors.single.category,
          BootstrapParseFailureCategory.unsupportedValue);
    });

    for (final network in <Object?>['', 'ZCASH', 1, null]) {
      test('rejects invalid network $network', () async {
        final value = document()..['network'] = network;
        expect((await parse(value)).success, isFalse);
      });
    }

    test('rejects missing servers', () async {
      final value = document()..remove('servers');
      expect((await parse(value)).validationErrors.single.category,
          BootstrapParseFailureCategory.missingField);
    });

    for (final servers in <Object?>[null, <String, dynamic>{}, <dynamic>[]]) {
      test('rejects invalid servers value $servers', () async {
        final value = document()..['servers'] = servers;
        expect((await parse(value)).success, isFalse);
      });
    }

    test('rejects more than 64 servers', () async {
      final servers = List.generate(
          65,
          (index) => server(
              id: 'server-$index', grpcUrl: 'https://server-$index.example'));
      expect((await parse(document(servers: servers))).success, isFalse);
    });
  });

  group('server failures', () {
    test('rejects duplicate ids', () async {
      final result = await parse(document(servers: [
        server(),
        server(grpcUrl: 'https://other.example'),
      ]));
      expect(result.validationErrors.single.category,
          BootstrapParseFailureCategory.duplicateServer);
    });

    test('rejects equivalent duplicate URLs', () async {
      final result = await parse(document(servers: [
        server(grpcUrl: 'https://EXAMPLE.com'),
        server(id: 'other', grpcUrl: 'https://example.com/'),
      ]));
      expect(result.validationErrors.single.category,
          BootstrapParseFailureCategory.duplicateServer);
    });

    for (final url in [
      'not a URI',
      '/relative',
      'https:///missing-host',
      'http://wallet.buck.red',
      'https://user:secret@wallet.buck.red',
    ]) {
      test('rejects invalid grpcUrl without echoing it: $url', () async {
        final result = await parse(document(servers: [server(grpcUrl: url)]));
        expect(result.validationErrors.single.category,
            BootstrapParseFailureCategory.invalidUri);
        expect(result.validationErrors.single.message, isNot(contains(url)));
      });
    }

    for (final priority in [-1, 1001]) {
      test('rejects priority $priority', () async {
        expect(
            (await parse(document(servers: [server(priority: priority)])))
                .success,
            isFalse);
      });
    }

    test('rejects non-integer priority', () async {
      final value = document();
      (value['servers'] as List).single['priority'] = 1.5;
      expect((await parse(value)).validationErrors.single.category,
          BootstrapParseFailureCategory.wrongType);
    });

    test('rejects invalid enabled', () async {
      final value = document();
      (value['servers'] as List).single['enabled'] = 'true';
      expect((await parse(value)).validationErrors.single.category,
          BootstrapParseFailureCategory.wrongType);
    });

    for (final field in ['displayName', 'id', 'grpcUrl']) {
      test('rejects missing $field', () async {
        final value = document();
        (value['servers'] as List).single.remove(field);
        expect((await parse(value)).validationErrors.single.category,
            BootstrapParseFailureCategory.missingField);
      });
    }

    test('rejects non-ASCII id', () async {
      expect((await parse(document(servers: [server(id: 'bück')]))).success,
          isFalse);
    });
  });
}
