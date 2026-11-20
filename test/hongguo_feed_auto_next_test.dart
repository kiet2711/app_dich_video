import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ksub/data/repository/settings_repository.dart';
import 'package:ksub/domain/media/hongguo/hongguo_cloud_account_service.dart';
import 'package:ksub/domain/media/hongguo_resolver.dart';
import 'package:ksub/ui/hongguo/feed/hongguo_feed_screen.dart';

HongguoDramaItem _sampleDrama() {
  return const HongguoDramaItem(
    seriesId: 'drama-1',
    title: 'Phim Test',
    cover: '',
    episodeCount: 3,
    vidList: ['vid-1', 'vid-2', 'vid-3'],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => null,
        );
    SharedPreferences.setMockInitialValues(<String, Object>{
      'hongguo_feed_tab': 'discover',
      'hongguo_translate_enabled': false,
    });
    HongguoCloudAccountService.instance.resetForTesting();
  });

  test('resolveHongguoFeedAutoNextOnBootstrap resets to false on normal feed', () {
    expect(
      resolveHongguoFeedAutoNextOnBootstrap(
        isDramaEpisodeMode: false,
        persistedSetting: true,
      ),
      isFalse,
    );
    expect(
      resolveHongguoFeedAutoNextOnBootstrap(
        isDramaEpisodeMode: true,
        persistedSetting: true,
      ),
      isTrue,
    );
    expect(
      resolveHongguoFeedAutoNextOnBootstrap(
        isDramaEpisodeMode: true,
        persistedSetting: false,
      ),
      isFalse,
    );
  });

  testWidgets('HongguoFeedAutoNextButton hides pre-translate dot when OFF', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: HongguoFeedAutoNextButton(
            isActive: false,
            isPreTranslating: true,
            onTap: () {},
          ),
        ),
      ),
    );

    expect(find.text('Tự đổi tập'), findsOneWidget);
    expect(find.byIcon(Icons.skip_next_rounded), findsOneWidget);
    expect(find.byIcon(Icons.playlist_play_rounded), findsNothing);
    final icon = tester.widget<Icon>(find.byIcon(Icons.skip_next_rounded));
    expect(icon.color, equals(Colors.white));

    // No orange pre-translating dot should be rendered when inactive.
    final orangeDots = tester.widgetList<Container>(find.byType(Container)).where(
      (c) {
        final dec = c.decoration;
        return dec is BoxDecoration &&
            dec.shape == BoxShape.circle &&
            dec.color == const Color(0xFFFF6A00);
      },
    );
    expect(orangeDots, isEmpty);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: HongguoFeedAutoNextButton(
            isActive: true,
            isPreTranslating: true,
            onTap: () {},
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.playlist_play_rounded), findsOneWidget);
    expect(find.byIcon(Icons.skip_next_rounded), findsNothing);
    final activeDots = tester.widgetList<Container>(find.byType(Container)).where(
      (c) {
        final dec = c.decoration;
        return dec is BoxDecoration &&
            dec.shape == BoxShape.circle &&
            dec.color == const Color(0xFFFF6A00);
      },
    );
    expect(activeDots, hasLength(1));
  });

  testWidgets(
    'normal discover feed always bootstraps Auto-Next as OFF even if stale setting was true',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'hongguo_feed_tab': 'discover',
        'hongguo_translate_enabled': false,
        'hongguo_auto_next_ep': true,
      });

      await tester.pumpWidget(
        MaterialApp(
          home: HongguoFeedScreen(
            discoverDramas: <HongguoDramaItem>[_sampleDrama()],
            enablePlayer: false,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('Tự đổi tập'), findsOneWidget);
      expect(find.byIcon(Icons.skip_next_rounded), findsOneWidget);
      expect(find.byIcon(Icons.playlist_play_rounded), findsNothing);

      final settings = await SettingsRepository.getInstance();
      expect(settings.hongguoAutoNextEpisode, isFalse);
    },
  );

  testWidgets(
    'exiting drama episode mode resets Auto-Next button to OFF on normal discover feed',
    (tester) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        MaterialApp(
          home: HongguoFeedScreen(
            discoverDramas: <HongguoDramaItem>[_sampleDrama()],
            enablePlayer: false,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));

      final buttonFinder = find.byType(HongguoFeedAutoNextButton);
      final offIconFinder = find.descendant(
        of: buttonFinder,
        matching: find.byIcon(Icons.skip_next_rounded),
      );
      final onIconFinder = find.descendant(
        of: buttonFinder,
        matching: find.byIcon(Icons.playlist_play_rounded),
      );

      expect(offIconFinder, findsOneWidget);
      expect(onIconFinder, findsNothing);

      // Tap Auto-Next on discover feed -> enters Drama Episode Mode & turns ON.
      await tester.tap(buttonFinder);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('Chọn tập · Trọn bộ 3 tập · Miễn phí'), findsOneWidget);
      expect(onIconFinder, findsOneWidget);
      expect(offIconFinder, findsNothing);
      final settings = await SettingsRepository.getInstance();
      expect(settings.hongguoAutoNextEpisode, isTrue);

      // Exit Drama Episode Mode back to normal Discover Feed via `< Tập ...` button.
      await tester.tap(find.byIcon(Icons.arrow_back_ios_new_rounded));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('Xem trọn bộ · Toàn bộ 3 tập'), findsOneWidget);
      expect(find.text('Tự đổi tập'), findsOneWidget);
      expect(offIconFinder, findsOneWidget);
      expect(onIconFinder, findsNothing);
      expect(settings.hongguoAutoNextEpisode, isFalse);

      // Also verify system back from Drama Episode Mode resets Auto-Next to OFF.
      await tester.tap(buttonFinder);
      await tester.pump(const Duration(milliseconds: 200));
      expect(onIconFinder, findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('Xem trọn bộ · Toàn bộ 3 tập'), findsOneWidget);
      expect(offIconFinder, findsOneWidget);
      expect(onIconFinder, findsNothing);
      expect(settings.hongguoAutoNextEpisode, isFalse);
    },
  );
}
