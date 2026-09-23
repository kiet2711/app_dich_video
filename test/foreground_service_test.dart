import 'package:capsub_flutter/domain/service/foreground_service_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'ForegroundServiceManager methods complete safely on non-Android platforms',
    () async {
      // In unit tests running on desktop/host, Platform.isAndroid is false,
      // so these methods must return immediately without throwing errors.
      await expectLater(
        ForegroundServiceManager.start(
          title: 'Test Title',
          message: 'Test Message',
          progress: 10,
          maxProgress: 100,
        ),
        completes,
      );

      await expectLater(
        ForegroundServiceManager.update(
          title: 'Updated Title',
          message: 'Updated Message',
          progress: 50,
          maxProgress: 100,
        ),
        completes,
      );

      await expectLater(ForegroundServiceManager.stop(), completes);
    },
  );
}
