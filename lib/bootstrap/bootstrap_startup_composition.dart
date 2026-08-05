import '../store2.dart' show serverCoordinator;
import 'bootstrap_lkg_cache.dart';
import 'bootstrap_orchestrator.dart';
import 'bootstrap_parser.dart';
import 'bootstrap_startup_integration.dart';
import 'bootstrap_transport.dart';

/// Optional build-time URI: `--dart-define=BUCK_BOOTSTRAP_URL=https://...`.
///
/// HTTPS and schema validation do not authenticate configuration. Cached data
/// is structurally Last-Known-Good only; Stage 6 will add signatures. Compiled
/// FR1/FR2 remain the availability anchor.
const String buckBootstrapUrl = String.fromEnvironment('BUCK_BOOTSTRAP_URL');

final BootstrapParser bootstrapParser = const BootstrapParser();
final BootstrapTransport bootstrapTransport = const BootstrapTransport();
final FileBootstrapCache bootstrapCache =
    FileBootstrapCache(parser: bootstrapParser);
final BootstrapOrchestrator bootstrapOrchestrator = BootstrapOrchestrator(
  cache: bootstrapCache,
  parser: bootstrapParser,
  transport: bootstrapTransport,
);
final BootstrapRemoteConfiguration bootstrapRemoteConfiguration =
    parseBootstrapRemoteConfiguration(buckBootstrapUrl);
final BootstrapStartupIntegration bootstrapStartupIntegration =
    BootstrapStartupIntegration(
  orchestrator: bootstrapOrchestrator,
  coordinator: serverCoordinator,
  remoteUri: bootstrapRemoteConfiguration.remoteUri,
  remoteConfigured: bootstrapRemoteConfiguration.configured,
  configurationDiagnostic: bootstrapRemoteConfiguration.diagnosticMessage,
);
