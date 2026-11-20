import 'package:ksub/data/repository/settings_repository.dart';
import 'package:ksub/domain/media/bilibili_resolver.dart';
import 'package:ksub/ui/bilibili/bilibili_account_sheet.dart';
import 'package:ksub/ui/bilibili/bilibili_screen.dart';
import 'package:ksub/ui/bilibili/bilibili_settings_sheet.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const MethodChannel _secureStorageChannel = MethodChannel(
  'plugins.it_nomads.com/flutter_secure_storage',
);

final Map<String, String> _mockSecureStorage = <String, String>{};

Dio _createMockBilibiliDio() {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        final path = options.uri.path;
        if (path == '/x/web-interface/nav') {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: <String, dynamic>{
                'code': 0,
                'data': <String, dynamic>{
                  'isLogin': true,
                  'mid': 123456,
                  'uname': 'BiliTester',
                  'face': '',
                  'vipStatus': 1,
                  'vipType': 2,
                  'level_info': <String, dynamic>{'current_level': 5},
                },
              },
            ),
          );
          return;
        }
        if (path == '/x/web-interface/history/cursor') {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: <String, dynamic>{
                'code': 0,
                'data': <String, dynamic>{
                  'cursor': <String, dynamic>{'max': 0, 'view_at': 0},
                  'list': [
                    <String, dynamic>{
                      'title': 'Synced Bilibili Episode',
                      'cover': '',
                      'duration': 300,
                      'progress': 90,
                      'view_at': 170000900,
                      'author_name': 'OfficialUP',
                      'show_title': '第2话',
                      'history': <String, dynamic>{
                        'business': 'archive',
                        'bvid': 'BV1SYNC0001',
                        'oid': 777,
                      },
                    },
                  ],
                },
              },
            ),
          );
          return;
        }
        handler.resolve(
          Response(
            requestOptions: options,
            statusCode: 200,
            data: <String, dynamic>{'code': 0, 'data': <String, dynamic>{}},
          ),
        );
      },
    ),
  );
  return dio;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_secureStorageChannel, (call) async {
          final args = (call.arguments as Map?)?.cast<dynamic, dynamic>() ?? const {};
          final key = args['key']?.toString() ?? '';
          switch (call.method) {
            case 'read':
              return _mockSecureStorage[key];
            case 'write':
              _mockSecureStorage[key] = args['value']?.toString() ?? '';
              return null;
            case 'delete':
              _mockSecureStorage.remove(key);
              return null;
            case 'deleteAll':
              _mockSecureStorage.clear();
              return null;
            case 'readAll':
              return Map<String, String>.from(_mockSecureStorage);
            case 'containsKey':
              return _mockSecureStorage.containsKey(key);
            default:
              return null;
          }
        });
  });

  setUp(() async {
    _mockSecureStorage.clear();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = await SettingsRepository.getInstance();
    settings.bilibiliSessData = '';
  });

  testWidgets('BilibiliSettingsSheet separates settings from account login',
      (tester) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: BilibiliSettingsSheet(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Cài đặt Bilibili'), findsOneWidget);
    expect(find.text('Đăng nhập QR / Cookie Bilibili'), findsNothing);
    expect(find.text('Tài khoản Bilibili'), findsNothing);
  });

  testWidgets('BilibiliAccountSheet displays profile and synced watch history',
      (tester) async {
    final settings = await SettingsRepository.getInstance();
    settings.bilibiliSessData = 'mock_sessdata';

    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    BilibiliWatchHistoryEntry? openedEntry;
    final resolver = BilibiliResolver(dio: _createMockBilibiliDio());

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BilibiliAccountSheet(
            resolver: resolver,
            translateTitles: false,
            onOpenVideo: (entry) async {
              openedEntry = entry;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Tài khoản Bilibili'), findsOneWidget);
    expect(find.text('BiliTester'), findsOneWidget);
    expect(find.text('Synced Bilibili Episode'), findsOneWidget);
    expect(find.text('01:30 / 05:00'), findsOneWidget);

    await tester.tap(find.text('Synced Bilibili Episode'));
    await tester.pump();

    expect(openedEntry, isNotNull);
    expect(openedEntry!.item.bvid, 'BV1SYNC0001');
    expect(openedEntry!.resumePositionMs, 90000);
  });

  testWidgets('BilibiliScreen header keeps Avatar, Search, Translate, Settings without top AI button',
      (tester) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      const MaterialApp(
        home: BilibiliScreen(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    final avatarFinder = find.byTooltip('Đăng nhập & Lịch sử Bilibili');
    final searchFinder = find.byType(TextField);
    final translateFinder = find.byIcon(Icons.translate_rounded);
    final settingsFinder = find.byIcon(Icons.settings_rounded);

    expect(avatarFinder, findsOneWidget);
    expect(searchFinder, findsOneWidget);
    expect(translateFinder, findsOneWidget);
    expect(settingsFinder, findsOneWidget);

    final avatarBox = tester.getRect(avatarFinder);
    final searchBox = tester.getRect(searchFinder);
    final translateBox = tester.getRect(translateFinder);
    final settingsBox = tester.getRect(settingsFinder);

    expect(avatarBox.right, lessThan(searchBox.left));
    expect(searchBox.right, lessThan(translateBox.left));
    expect(translateBox.right, lessThan(settingsBox.left));
    expect(avatarBox.center.dy, lessThan(120));
    expect(settingsBox.center.dy, lessThan(120));

    // Top bar AI Assistant button was removed; FAB remains at the bottom.
    expect(find.byTooltip('Trợ lý AI tìm video Bilibili'), findsNothing);
    expect(find.text('Trợ lý AI'), findsOneWidget);
  });
}
