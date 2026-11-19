import 'dart:io';

import 'package:capsub_flutter/data/repository/settings_repository.dart';
import 'package:capsub_flutter/main.dart';
import 'package:capsub_flutter/ui/settings/settings_screen.dart';
import 'package:capsub_flutter/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('capsub_theme_test_');
    SharedPreferences.setMockInitialValues({});
    AppThemeController.instance.resetForTesting();

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (call) async {
          if (call.method == 'readAll') {
            return <String, String>{};
          }
          return '';
        });

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
          return tempDir.path;
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    AppThemeController.instance.resetForTesting();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('AppThemeController & UI Redesign Tests', () {
    test('controller defaults to fresh bright theme and floating pill nav', () {
      final p = AppThemeController.instance.palette;
      expect(p.mode.id, 'fresh');
      expect(p.navStyle, 'floating');
      expect(p.isDark, isFalse);
      expect(p.isFloatingNav, isTrue);
      expect(p.accentFor(AppTabId.studio).toARGB32(), 0xFF5B5CF6);
      expect(p.accentFor(AppTabId.hongguo).toARGB32(), 0xFFFF4D2D);
      expect(p.accentFor(AppTabId.bilibili).toARGB32(), 0xFFFB7299);
      expect(p.accentFor(AppTabId.history).toARGB32(), 0xFF7C3AED);
    });

    test('persists theme mode, nav style, tab accent and resets cleanly', () async {
      final controller = AppThemeController.instance;
      await controller.setThemeMode('midnight');
      await controller.setNavStyle('docked');
      await controller.setTabAccent(AppTabId.studio, const Color(0xFF0EA5E9));

      expect(controller.palette.mode.id, 'midnight');
      expect(controller.palette.isDark, isTrue);
      expect(controller.palette.navStyle, 'docked');
      expect(controller.palette.isFloatingNav, isFalse);
      expect(controller.palette.accentFor(AppTabId.studio).toARGB32(), 0xFF0EA5E9);

      // Verify persistence in SettingsRepository & reload round-trip
      controller.resetForTesting();
      expect(controller.palette.mode.id, 'fresh');

      final settings = await SettingsRepository.getInstance();
      await controller.loadFromSettings(settings);
      expect(controller.palette.mode.id, 'midnight');
      expect(controller.palette.navStyle, 'docked');
      expect(controller.palette.accentFor(AppTabId.studio).toARGB32(), 0xFF0EA5E9);

      // Reset back to defaults
      await controller.resetToDefaults();
      expect(controller.palette.mode.id, 'fresh');
      expect(controller.palette.navStyle, 'floating');
      expect(controller.palette.accentFor(AppTabId.studio).toARGB32(), 0xFF5B5CF6);
      expect(settings.uiThemeMode, 'fresh');
      expect(settings.uiNavStyle, 'floating');
    });

    testWidgets(
      'SettingsScreen renders Appearance controls and Kiểu A Accordions cleanly',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(412, 915));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        await tester.pumpWidget(
          ListenableBuilder(
            listenable: AppThemeController.instance,
            builder: (_, _) => MaterialApp(
              theme: buildAppTheme(),
              home: const SettingsScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Giao diện & Màu sắc'), findsOneWidget);
        expect(find.text('Viên thuốc nổi'), findsNothing);

        // Tap to expand Giao diện & Màu sắc Kiểu A Accordion
        await tester.tap(find.text('Giao diện & Màu sắc'));
        await tester.pumpAndSettle();

        expect(find.text('Viên thuốc nổi'), findsOneWidget);
        expect(find.text('Liền đáy gốc'), findsOneWidget);

        // Switch theme mode & nav style live (scroll horizontal preset list first)
        await tester.ensureVisible(find.text('Tối hiện đại'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Tối hiện đại'));
        await tester.pumpAndSettle();
        expect(AppThemeController.instance.palette.mode.id, 'midnight');

        await tester.ensureVisible(find.text('Liền đáy gốc'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Liền đáy gốc'));
        await tester.pumpAndSettle();
        expect(AppThemeController.instance.palette.navStyle, 'docked');

        // Expand AI Translation Kiểu A Accordion
        final verticalScrollable = find.byType(Scrollable).first;
        await tester.scrollUntilVisible(
          find.text('AI Dịch thuật (Gemini & Groq)'),
          200,
          scrollable: verticalScrollable,
        );
        await tester.tap(find.text('AI Dịch thuật (Gemini & Groq)'));
        await tester.pumpAndSettle();
        expect(find.text('Kiểm tra Key Gemini (Sống / Chết)'), findsOneWidget);

        // Expand CapCut Concurrency Kiểu A Accordion
        await tester.scrollUntilVisible(
          find.text('Đa luồng & Phân đoạn CapCut'),
          250,
          scrollable: verticalScrollable,
        );
        await tester.tap(find.text('Đa luồng & Phân đoạn CapCut'));
        await tester.pumpAndSettle();
        expect(find.text('SỐ LUỒNG NHẬN DIỆN CAPCUT (STT):'), findsOneWidget);

        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'MainNavigation displays Floating Pill nav and switches all 4 tabs without errors',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(412, 915));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        await tester.pumpWidget(
          ListenableBuilder(
            listenable: AppThemeController.instance,
            builder: (_, _) => MaterialApp(
              theme: buildAppTheme(),
              home: const MainNavigation(),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 250));
        await tester.pump(const Duration(milliseconds: 250));

        // Floating Pill nav initially shows label only for active Studio tab,
        // and reveals each tab label when selected.
        expect(find.text('Studio'), findsOneWidget);

        await tester.tap(find.byIcon(Icons.play_circle_filled_rounded).last);
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Hồng Quả'), findsWidgets);

        await tester.tap(find.byIcon(Icons.tv_rounded).last);
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Bilibili'), findsWidgets);

        await tester.tap(find.byIcon(Icons.schedule_rounded).last);
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Lịch Sử'), findsWidgets);

        await tester.tap(find.byIcon(Icons.auto_awesome_rounded).last);
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Studio'), findsOneWidget);

        expect(tester.takeException(), isNull);
      },
    );
  });
}
