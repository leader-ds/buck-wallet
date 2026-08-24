import 'package:flutter_test/flutter_test.dart';

import 'package:YWallet/pages/main/receiver_option.dart';

void main() {
  test('parent observes valid, no-selection, valid lifecycle', () {
    final coordinator = ReceiverSelectionCoordinator();
    final delivered = <int?>[];

    void deliver(ReceiverSelectionNotification? notification) {
      expect(notification, isNotNull);
      if (coordinator.consume(notification!)) {
        delivered.add(notification.addressMode);
      }
    }

    deliver(coordinator.update(1, notifyCurrent: true));
    deliver(coordinator.update(null));
    expect(coordinator.currentAddressMode, isNull);
    deliver(coordinator.update(1));

    expect(delivered, <int?>[1, null, 1]);
  });

  test('superseded queued receiver notification is rejected', () {
    final coordinator = ReceiverSelectionCoordinator();
    final staleReceiver = coordinator.update(3, notifyCurrent: true)!;
    final noSelection = coordinator.update(null)!;

    expect(coordinator.consume(staleReceiver), isFalse);
    expect(coordinator.consume(noSelection), isTrue);
    expect(coordinator.currentAddressMode, isNull);
  });

  test('semantic duplicates are not delivered', () {
    final coordinator = ReceiverSelectionCoordinator();
    final initial = coordinator.update(1, notifyCurrent: true)!;
    expect(coordinator.consume(initial), isTrue);
    expect(coordinator.update(1), isNull);

    final forced = coordinator.update(1, notifyCurrent: true)!;
    expect(coordinator.consume(forced), isFalse);
  });
}
