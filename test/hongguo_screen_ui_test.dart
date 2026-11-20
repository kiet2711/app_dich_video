import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ksub/domain/media/hongguo/hongguo_cloud_account_service.dart';
import 'package:ksub/domain/media/hongguo/hongguo_discovery_service.dart';
import 'package:ksub/domain/media/hongguo_resolver.dart';
import 'package:ksub/ui/hongguo/hongguo_screen.dart';

class _FakeTheaterDiscoveryService extends HongguoDiscoveryService {
  _FakeTheaterDiscoveryService() : super.forSubclass();

  int officialCalls = 0;
  final Map<HongguoGenreKind, int> discoveryCallsByKind = {};

  @override
  Future<HongguoOfficialFeedPage> fetchOfficialRecommendations({
    HongguoOfficialFeedCursor cursor = const HongguoOfficialFeedCursor(),
  }) async {
    officialCalls++;
    return HongguoOfficialFeedPage(
      items: List.generate(
        16,
        (i) => HongguoDramaItem(
          seriesId: 'disc_${officialCalls}_$i',
          title: 'Tìm phim #$i (lần $officialCalls)',
          cover: '',
          episodeCount: 50,
        ),
      ),
      nextCursor: cursor.copyWith(offset: cursor.offset + 16, sessionId: 's1'),
    );
  }

  @override
  Future<HongguoDiscoveryPage> fetchDiscovery(
    HongguoDiscoverySelection selection, {
    HongguoDiscoveryCursor? cursor,
    Set<String>? seenIds,
    bool useDefaultFeedSort = false,
  }) async {
    final kind = selection.genreKind;
    final count = (discoveryCallsByKind[kind] ?? 0) + 1;
    discoveryCallsByKind[kind] = count;
    return HongguoDiscoveryPage(
      items: List.generate(
        16,
        (i) => HongguoDramaItem(
          seriesId: '${kind.id}_${count}_$i',
          title: '${kind.shortLabel} #$i (lần $count)',
          cover: '',
          episodeCount: 40,
          sourceCategory: kind.categorySlug,
        ),
      ),
      selectorGroups: HongguoDiscoveryService.defaultSelectorGroups(kind),
      nextCursor: HongguoDiscoveryCursor(
        offset: (cursor?.offset ?? 0) + 16,
        sessionId: 'ch-${kind.id}',
        page: (cursor?.page ?? 1) + 1,
      ),
      hasMore: true,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => null,
        );
    SharedPreferences.setMockInitialValues(<String, Object>{});
    HongguoCloudAccountService.instance.resetForTesting();
  });

  testWidgets('HongguoScreen top bar matches Bilibili layout & translate sits at bottom',
      (tester) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      const MaterialApp(
        home: HongguoScreen(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    // Title "Phim Ngắn Hồng Quả" and top AI assistant tooltip are removed.
    expect(find.text('Phim Ngắn Hồng Quả'), findsNothing);
    expect(find.byTooltip('Trợ lý AI tìm phim (Gemini Live)'), findsNothing);

    // Top bar has avatar on left -> search field -> Feed button -> Settings button on right.
    final avatarFinder = find.byIcon(Icons.account_circle_rounded);
    final searchFieldFinder = find.byType(TextField);
    final feedFinder = find.byIcon(Icons.swipe_vertical_rounded);
    final settingsFinder = find.byIcon(Icons.settings_rounded);

    expect(avatarFinder, findsOneWidget);
    expect(searchFieldFinder, findsOneWidget);
    expect(feedFinder, findsOneWidget);
    expect(settingsFinder, findsOneWidget);

    final avatarBox = tester.getRect(avatarFinder);
    final searchBox = tester.getRect(searchFieldFinder);
    final feedBox = tester.getRect(feedFinder);
    final settingsBox = tester.getRect(settingsFinder);

    expect(avatarBox.right, lessThan(searchBox.left));
    expect(searchBox.right, lessThan(feedBox.left));
    expect(feedBox.right, lessThan(settingsBox.left));
    // All four controls sit in the top header band.
    expect(avatarBox.center.dy, lessThan(120));
    expect(settingsBox.center.dy, lessThan(120));

    // Infinite scroll removed the bottom "Tải thêm đề xuất" / "Đổi loạt đề xuất" button;
    // translate button still sits in the bottom bar.
    final translateFinder = find.byIcon(Icons.translate_rounded);
    expect(find.text('Tải thêm đề xuất mới từ Hồng Quả'), findsNothing);
    expect(find.text('Tải thêm đề xuất'), findsNothing);
    expect(find.text('Đổi loạt đề xuất'), findsNothing);
    expect(translateFinder, findsOneWidget);

    final translateBox = tester.getRect(translateFinder);
    expect(translateBox.center.dy, greaterThan(700));

    // Typing a query reveals clear + "Tìm" inside search bar without overflow.
    await tester.enterText(searchFieldFinder, 'test');
    await tester.pump();
    expect(find.text('Tìm'), findsOneWidget);

    // Toggling translate button switches state cleanly.
    await tester.tap(translateFinder);
    await tester.pump();
    expect(find.text('Dịch: TẮT'), findsOneWidget);
    final toggleButton = find.ancestor(
      of: find.text('Dịch: TẮT'),
      matching: find.byType(InkWell),
    );
    expect(
      find.descendant(
        of: toggleButton,
        matching: find.byIcon(Icons.translate_outlined),
      ),
      findsOneWidget,
    );

    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'HongguoScreen renders theater tabs, Tìm phim pills, and quick channel chips cleanly',
    (tester) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        const MaterialApp(
          home: HongguoScreen(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));

      // 4 tab cấp 1 khớp app gốc + Phim AI
      expect(find.text('Tìm phim'), findsOneWidget);
      expect(find.text('Người thật'), findsOneWidget);
      expect(find.text('Hoạt hình'), findsOneWidget);
      expect(find.text('Phim AI'), findsOneWidget);

      // 3 nút nhanh trong Tìm phim
      expect(find.text('Bộ lọc'), findsOneWidget);
      expect(find.text('BXH'), findsOneWidget);
      expect(find.text('Phim mới'), findsOneWidget);

      // Chuyển sang Người thật -> thấy dải chip lọc nhanh như 真人剧
      await tester.tap(find.text('Người thật'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Đô thị'), findsOneWidget);
      expect(find.text('Học đường'), findsOneWidget);
      expect(find.text('Nông thôn'), findsOneWidget);

      // Chuyển sang Hoạt hình -> thấy dải chip lọc nhanh như 漫剧
      await tester.tap(find.text('Hoạt hình'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Xuyên không'), findsOneWidget);
      final chipScrollable = find.ancestor(
        of: find.text('Xuyên không'),
        matching: find.byType(Scrollable),
      );
      await tester.scrollUntilVisible(
        find.text('Chính kịch'),
        120,
        scrollable: chipScrollable,
      );
      expect(find.text('Chính kịch'), findsOneWidget);

      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Switching between 4 Hongguo tabs preserves list and scroll position without reload, and evicts on memory pressure',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'hongguo_translate_enabled': false,
      });
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final fakeDiscovery = _FakeTheaterDiscoveryService();

      await tester.pumpWidget(
        MaterialApp(
          home: HongguoScreen(discoveryService: fakeDiscovery),
        ),
      );
      for (var i = 0; i < 8 && fakeDiscovery.officialCalls == 0; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pump(const Duration(milliseconds: 50));

      expect(fakeDiscovery.officialCalls, 1);
      expect(find.text('Tìm phim #0 (lần 1)'), findsOneWidget);

      // Cuộn danh sách Tìm phim xuống sâu
      final gridScrollable = find.descendant(
        of: find.byType(CustomScrollView),
        matching: find.byType(Scrollable),
      );
      await tester.drag(gridScrollable, const Offset(0, -600));
      await tester.pump(const Duration(milliseconds: 100));

      final scrollController = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller!;
      final savedDiscoverOffset = scrollController.offset;
      expect(savedDiscoverOffset, greaterThan(300));

      // Chuyển sang tab Người thật -> tải 1 lần và cuộn xuống
      await tester.tap(find.text('Người thật'));
      for (var i = 0;
          i < 8 && (fakeDiscovery.discoveryCallsByKind[HongguoGenreKind.realPlay] ?? 0) == 0;
          i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pump(const Duration(milliseconds: 50));
      expect(fakeDiscovery.discoveryCallsByKind[HongguoGenreKind.realPlay], 1);
      expect(find.text('Người thật #0 (lần 1)'), findsOneWidget);

      await tester.drag(gridScrollable, const Offset(0, -450));
      await tester.pump(const Duration(milliseconds: 100));
      final savedRealOffset = scrollController.offset;
      expect(savedRealOffset, greaterThan(200));

      // Quay lại Tìm phim -> KHÔNG gọi API lại và giữ nguyên vị trí cuộn cũ!
      await tester.tap(find.text('Tìm phim'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(fakeDiscovery.officialCalls, 1);
      expect(scrollController.offset, closeTo(savedDiscoverOffset, 1.0));

      // Quay lại Người thật -> vẫn không gọi API lại, giữ đúng offset
      await tester.tap(find.text('Người thật'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(fakeDiscovery.discoveryCallsByKind[HongguoGenreKind.realPlay], 1);
      expect(scrollController.offset, closeTo(savedRealOffset, 1.0));

      // Hệ thống báo thiếu RAM -> dọn snapshot của tab đang ẩn ('discover'), giữ tab đang xem ('short_play')
      tester.binding.handleMemoryPressure();
      await tester.pump();

      // Quay lại Tìm phim sau khi bị dọn RAM -> tự động load lại sạch
      await tester.tap(find.text('Tìm phim'));
      for (var i = 0; i < 8 && fakeDiscovery.officialCalls < 2; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pump(const Duration(milliseconds: 50));
      expect(fakeDiscovery.officialCalls, 2);
      expect(find.text('Tìm phim #0 (lần 2)'), findsOneWidget);

      expect(tester.takeException(), isNull);
    },
  );
}

