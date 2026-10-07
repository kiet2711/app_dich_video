import 'package:capsub_flutter/data/repository/settings_repository.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (MethodCall methodCall) async {
            return '';
          },
        );
    SharedPreferences.setMockInitialValues({});
  });

  group('Hongguo Playback Speed Setting', () {
    test('defaults to 1.0x when not set', () async {
      final settings = await SettingsRepository.getInstance();
      expect(settings.hongguoPlaybackSpeed, 1.0);
    });

    test('persists and clamps custom playback speed', () async {
      final settings = await SettingsRepository.getInstance();
      settings.hongguoPlaybackSpeed = 1.5;
      expect(settings.hongguoPlaybackSpeed, 1.5);

      // Clamping limits (0.5 -> 2.0)
      settings.hongguoPlaybackSpeed = 3.0;
      expect(settings.hongguoPlaybackSpeed, 2.0);

      settings.hongguoPlaybackSpeed = 0.2;
      expect(settings.hongguoPlaybackSpeed, 0.5);
    });
  });
}
