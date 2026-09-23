import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:capsub_flutter/data/model/subtitle_item.dart';
import 'package:capsub_flutter/data/repository/settings_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Subtitle Customization Tests', () {
    late SettingsRepository settings;

    setUp(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (MethodCall methodCall) async {
              return '';
            },
          );
      SharedPreferences.setMockInitialValues({
        'sub_font_size': 20.0,
        'sub_offset_y': 0.0,
        'sub_mode': 'translated',
        'selected_font_family': '',
        'custom_fonts': <String>['SVN-Futura', 'Montserrat'],
      });
      settings = await SettingsRepository.getInstance();
    });

    test('Subtitle font size clamps properly between 5.0 and 30.0', () {
      settings.subtitleFontSize = 35.0;
      expect(settings.subtitleFontSize, equals(30.0));

      settings.subtitleFontSize = 2.0;
      expect(settings.subtitleFontSize, equals(5.0));

      settings.subtitleFontSize = 14.5;
      expect(settings.subtitleFontSize, equals(14.5));
    });

    test('Subtitle offset Y and mode getters/setters work properly', () {
      settings.subtitleOffsetY = 50.0;
      expect(settings.subtitleOffsetY, equals(50.0));

      settings.subtitleMode = 'bilingual';
      expect(settings.subtitleMode, equals('bilingual'));
    });

    test('Custom font family settings work properly', () {
      expect(settings.customFonts, contains('SVN-Futura'));
      expect(settings.customFonts, contains('Montserrat'));

      settings.selectedFontFamily = 'SVN-Futura';
      expect(settings.selectedFontFamily, equals('SVN-Futura'));

      final list = List<String>.from(settings.customFonts)..add('Roboto-Custom');
      settings.customFonts = list;
      expect(settings.customFonts, contains('Roboto-Custom'));
    });

    test('Gemini batch size default and updating works properly', () {
      expect(settings.geminiBatchSize, equals(45));

      settings.geminiBatchSize = 80;
      expect(settings.geminiBatchSize, equals(80));

      settings.geminiBatchSize = 100;
      expect(settings.geminiBatchSize, equals(100));
    });

    test('SubtitleItem getDisplayText handles bilingual, translated, and original', () {
      final item = SubtitleItem(
        id: 1,
        startMs: 1000,
        endMs: 3000,
        originalText: '你好世界',
        translatedText: 'Xin chào thế giới',
      );

      expect(item.getDisplayText('original'), equals('你好世界'));
      expect(item.getDisplayText('translated'), equals('Xin chào thế giới'));
      expect(
        item.getDisplayText('bilingual'),
        equals('你好世界\nXin chào thế giới'),
      );
    });
  });
}
