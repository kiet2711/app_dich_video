import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:capsub_flutter/domain/media/hongguo/hongguo_cloud_account_service.dart';
import 'package:capsub_flutter/ui/hongguo/hongguo_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
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

    // Compact load-more button + translate button sit in the bottom bar.
    final loadMoreFinder = find.text('Tải thêm đề xuất');
    final translateFinder = find.byIcon(Icons.translate_rounded);
    expect(find.text('Tải thêm đề xuất mới từ Hồng Quả'), findsNothing);
    expect(loadMoreFinder, findsOneWidget);
    expect(translateFinder, findsOneWidget);

    final loadMoreBox = tester.getRect(loadMoreFinder);
    final translateBox = tester.getRect(translateFinder);
    expect(loadMoreBox.center.dy, greaterThan(700));
    expect(translateBox.center.dy, greaterThan(700));
    expect(loadMoreBox.right, lessThan(translateBox.left));

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
}

