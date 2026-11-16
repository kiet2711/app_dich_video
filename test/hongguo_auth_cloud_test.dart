import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:capsub_flutter/domain/media/hongguo/hongguo_auth_service.dart';
import 'package:capsub_flutter/domain/media/hongguo/hongguo_cloud_account_service.dart';
import 'package:capsub_flutter/domain/media/hongguo/hongguo_device_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    HongguoDeviceService.instance.resetForTesting();
    HongguoAuthService.instance.resetForTesting();
    HongguoCloudAccountService.instance.resetForTesting();

    // Provide mocked device registration so offline tests never hit network.
    final devDio = Dio();
    devDio.httpClientAdapter = _MockAdapter((_) async {
      return ResponseBody.fromString(
        jsonEncode(<String, dynamic>{
          'device_id_str': '3012345678901234567',
          'install_id_str': '3012345678901234568',
        }),
        200,
      );
    });
    HongguoDeviceService.instance.setDioForTesting(devDio);
  });

  group('HongguoAuthService (QR & Phone SMS)', () {
    test('authorizationAppUrl domain-locks deeplink and formatPhone handles VN/CN/overseas', () {
      const validUrl =
          'https://reading.snssdk.com/reading_offline/novelread/page/scan-code.html?token=tok1&qr_source_aid=513755';
      final link = HongguoAuthService.authorizationAppUrl(validUrl, 'tok1');
      expect(link, startsWith('dragon8662://webview?url='));
      expect(
        HongguoAuthService.authorizationAppUrl(
          validUrl.replaceFirst('reading.snssdk.com', 'evil.example'),
          'tok1',
        ),
        isEmpty,
      );
      expect(
        HongguoAuthService.authorizationAppUrl(validUrl, 'wrong-token'),
        isEmpty,
      );

      expect(HongguoAuthService.formatPhone('86', '138 0013 8000'), '13800138000');
      expect(HongguoAuthService.formatPhone('84', '0912345678'), '+84 912345678');
      expect(HongguoAuthService.formatPhone('886', '0912345678'), '+886 912345678');
      expect(
        () => HongguoAuthService.formatPhone('86', '12345'),
        throwsArgumentError,
      );
      expect(kHongguoCountryCodes.length, greaterThanOrEqualTo(55));
    });

    test('QR flow fetches PNG, follows official redirect, and stores session cookies', () async {
      final visited = <String>[];
      final dio = Dio();
      dio.httpClientAdapter = _MockAdapter((options) async {
        visited.add(options.uri.path);
        switch (options.uri.path) {
          case '/passport/web/get_qrcode/':
            return ResponseBody.fromString(
              jsonEncode(<String, dynamic>{
                'message': 'success',
                'data': <String, dynamic>{
                  'token': 'qr_tok_1',
                  'qrcode': base64Encode(utf8.encode('image')),
                  'expire_time': 180,
                },
              }),
              200,
              headers: <String, List<String>>{
                'set-cookie': <String>['passport_csrf_token=csrf1; Path=/'],
              },
            );
          case '/passport/web/check_qrconnect/':
            return ResponseBody.fromString(
              jsonEncode(<String, dynamic>{
                'message': 'success',
                'data': <String, dynamic>{
                  'status': '3',
                  'redirect_url': '/auth/complete',
                },
              }),
              200,
            );
          case '/auth/complete':
            return ResponseBody.fromString(
              'ok',
              200,
              headers: <String, List<String>>{
                'set-cookie': <String>['sessionid=sess_qr_ok; Path=/; HttpOnly'],
              },
            );
          case '/passport/account/info/v2/':
            return ResponseBody.fromString(
              jsonEncode(<String, dynamic>{
                'message': 'success',
                'data': <String, dynamic>{
                  'user_id': 'u_1001',
                  'name': 'UserQR',
                },
              }),
              200,
            );
          default:
            return ResponseBody.fromString('{}', 404);
        }
      });

      HongguoAuthService.instance.setDioForTesting(dio);
      final qr = await HongguoAuthService.instance.fetchQrCode();
      expect(qr.token, 'qr_tok_1');
      expect(utf8.decode(qr.qrImageBytes), 'image');

      final poll = await HongguoAuthService.instance.pollQrStatus(qr.token);
      expect(poll.status, HongguoQrPollStatus.confirmed);
      expect(poll.credentials?.cookie, contains('sessionid=sess_qr_ok'));
      expect(poll.credentials?.userName, 'UserQR');
      expect(poll.credentials.toString(), isNot(contains('sess_qr_ok')));
      expect(
        visited,
        <String>[
          '/passport/web/get_qrcode/',
          '/passport/web/check_qrconnect/',
          '/auth/complete',
          '/passport/account/info/v2/',
        ],
      );
    });

    test('SMS RetryGate blocks cooldown spam and stops immediately on wrong OTP (1102)', () async {
      var calls = 0;
      var sendMode = 'rate_limit';
      final dio = Dio();
      dio.httpClientAdapter = _MockAdapter((options) async {
        calls++;
        if (options.uri.path.contains('/send_code/')) {
          if (sendMode == 'rate_limit') {
            return ResponseBody.fromString(
              jsonEncode(<String, dynamic>{
                'message': 'error',
                'data': <String, dynamic>{
                  'error_code': 7,
                  'description': 'Quá nhanh',
                  'retry_time': 120,
                },
              }),
              200,
            );
          }
          if (sendMode == 'captcha') {
            return ResponseBody.fromString(
              jsonEncode(<String, dynamic>{
                'message': 'success',
                'data': <String, dynamic>{
                  'verify_center_decision_conf': '{}',
                },
              }),
              200,
            );
          }
          return ResponseBody.fromString(
            jsonEncode(<String, dynamic>{
              'message': 'success',
              'data': <String, dynamic>{
                'mobile': '138******00',
                'retry_time': 60,
                'mobile_ticket': 'tk_1',
              },
            }),
            200,
          );
        }
        return ResponseBody.fromString(
          jsonEncode(<String, dynamic>{
            'message': 'error',
            'data': <String, dynamic>{
              'error_code': 1102,
              'description': 'Sai mã OTP',
            },
          }),
          200,
        );
      });
      HongguoAuthService.instance.setDioForTesting(dio);

      // Rate limit blocks second immediate attempt without touching network.
      await expectLater(
        () => HongguoAuthService.instance.sendSmsCode('86', '13800000000'),
        throwsA(isA<HongguoAuthException>()),
      );
      await expectLater(
        () => HongguoAuthService.instance.sendSmsCode('86', '13800000000'),
        throwsA(isA<HongguoAuthException>()),
      );
      expect(calls, 1);

      // Captcha detection throws HongguoCaptchaRequiredException.
      HongguoAuthService.instance.smsRetryGate.reset();
      sendMode = 'captcha';
      await expectLater(
        () => HongguoAuthService.instance.sendSmsCode('86', '13800000000'),
        throwsA(isA<HongguoCaptchaRequiredException>()),
      );

      // Wrong OTP (1102) stops immediately on first verify attempt.
      sendMode = 'ok';
      await HongguoAuthService.instance.sendSmsCode('86', '13800000000');
      final beforeVerify = calls;
      await expectLater(
        () => HongguoAuthService.instance.verifySmsCode('999999'),
        throwsA(isA<HongguoAuthException>()),
      );
      expect(calls, beforeVerify + 1);
    });
  });

  group('HongguoCloudAccountService', () {
    const creds = HongguoAccountCredentials(
      cookie: 'sessionid=test-only',
      deviceId: '3012345678901234567',
      installId: '3012345678901234568',
    );

    test('validates biz_user_id, loads history with multi-detail, and uploads progress', () async {
      var uploadedPayloads = <Map<String, dynamic>>[];
      var favPresent = false;
      var favWrites = 0;

      final dio = Dio();
      dio.httpClientAdapter = _MockAdapter((options) async {
        expect(options.headers['Cookie'], 'sessionid=test-only');
        final path = options.uri.path;
        if (path == '/reading/user/info/v1/') {
          return ResponseBody.fromString(
            jsonEncode(<String, dynamic>{
              'code': 0,
              'data': <String, dynamic>{
                'biz_user_id': 'biz_999',
                'user_name': 'TesterHG',
              },
            }),
            200,
          );
        }
        if (path == '/reading/bookapi/read_progress/list/v1/') {
          return ResponseBody.fromString(
            jsonEncode(<String, dynamic>{
              'code': 0,
              'video_data': <Map<String, dynamic>>[
                <String, dynamic>{
                  'series_id': '123',
                  'vid': '456',
                  'vid_index': 3,
                  'current_play_time': 43210,
                  'current_total_time': 90000,
                  'last_watch_time': 1792500000,
                },
              ],
            }),
            200,
          );
        }
        if (path == '/reading/bookapi/multi-detail/v1/') {
          return ResponseBody.fromString(
            jsonEncode(<String, dynamic>{
              'code': 0,
              'data': <Map<String, dynamic>>[
                <String, dynamic>{
                  'book_id': '123',
                  'book_name': '云端测试剧',
                  'episode_cnt': 40,
                },
              ],
            }),
            200,
          );
        }
        if (path == '/reading/bookapi/bookshelf/video/info/v1/') {
          return ResponseBody.fromString(
            jsonEncode(<String, dynamic>{
              'code': 0,
              'data': <String, dynamic>{
                'video_shelf_info': favPresent
                    ? <Map<String, dynamic>>[
                        <String, dynamic>{
                          'series_title': '云端测试剧',
                          'video_data': <String, dynamic>{'series_id': '123'},
                        },
                      ]
                    : <Map<String, dynamic>>[],
              },
            }),
            200,
          );
        }
        if (path == '/reading/bookapi/bookshelf/video/update/v1/') {
          favWrites++;
          final rawBytes =
              await (options.data as Stream<List<int>>).expand((e) => e).toList();
          final body = jsonDecode(utf8.decode(rawBytes)) as Map<String, dynamic>;
          final op = body['update_bookshelf_video_list'][0]['video_shelf_operate_type'];
          favPresent = op == 0;
          return ResponseBody.fromString('{"code":0}', 200);
        }
        if (path == '/reading/bookapi/read_progress/upload/v1/') {
          final rawBytes =
              await (options.data as Stream<List<int>>).expand((e) => e).toList();
          uploadedPayloads.add(
            jsonDecode(utf8.decode(rawBytes)) as Map<String, dynamic>,
          );
          return ResponseBody.fromString('{"code":0}', 200);
        }
        if (path == '/reading/user/subscribe/list/v0/') {
          if (options.uri.queryParameters['is_online'] == 'true') {
            throw DioException(requestOptions: options);
          }
          return ResponseBody.fromString(
            jsonEncode(<String, dynamic>{
              'code': 0,
              'data': <String, dynamic>{
                'subscribe_items': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'subscribe_data': <String, dynamic>{
                      'series_id': '888',
                      'title': 'Sắp chiếu test',
                    },
                  },
                ],
              },
            }),
            200,
          );
        }
        return ResponseBody.fromString('{"code":0}', 200);
      });

      final cloud = HongguoCloudAccountService.instance;
      cloud.setDioForTesting(dio);
      await cloud.onLoginSucceeded(creds);

      expect(cloud.state.value.profile?.userName, 'TesterHG');
      expect(cloud.state.value.history.single.title, '云端测试剧');
      expect(cloud.state.value.history.single.episodeIndex, 3);
      expect(cloud.state.value.history.single.positionMs, 43210);
      expect(cloud.state.value.history.single.updatedAtMs, 1792500000000);

      // Reservations: online error stays isolated while upcoming succeeds.
      expect(cloud.state.value.onlineReservationsError, isNotNull);
      expect(cloud.state.value.upcomingReservations.single.seriesId, '888');

      // Favorites: idempotent pre-check + write + read-back confirm.
      await cloud.setFavorite(seriesId: '123', title: '云端测试剧', add: true);
      expect(cloud.state.value.isFavorite('123'), isTrue);
      await cloud.setFavorite(seriesId: '123', title: '云端测试剧', add: true);
      expect(favWrites, 1);

      // Progress upload payload matches CloudAccountTest contract.
      await cloud.uploadProgressNow(
        const HongguoCloudProgress(
          seriesId: '123',
          episodeId: '456',
          episodeIndex: 3,
          positionMs: 43210,
          durationMs: 90000,
          updatedAtMs: 1792500000000,
        ),
        episodeCount: 40,
      );
      expect(uploadedPayloads.length, 1);
      final book = uploadedPayloads.single['books'][0];
      expect(uploadedPayloads.single['write_mode'], 1);
      expect(book['book_id'], '123');
      expect(book['item_id'], '456');
      expect(book['vid_index'], 3);
      expect(book['current_play_time'], 43210);

      // Logout clears credentials and state.
      await cloud.logout();
      expect(cloud.state.value.isLoggedIn, isFalse);
      expect(cloud.state.value.history, isEmpty);
      expect(cloud.state.value.upcomingReservations, isEmpty);
    });

    test('empty biz_user_id throws HongguoAccountNotProvisionedException', () async {
      final dio = Dio();
      dio.httpClientAdapter = _MockAdapter((_) async {
        return ResponseBody.fromString(
          jsonEncode(<String, dynamic>{
            'code': 0,
            'data': <String, dynamic>{'biz_user_id': '', 'user_name': ''},
          }),
          200,
        );
      });
      final cloud = HongguoCloudAccountService.instance;
      cloud.setDioForTesting(dio);
      await expectLater(
        () => cloud.fetchProfile(creds),
        throwsA(isA<HongguoAccountNotProvisionedException>()),
      );
    });
  });
}

class _MockAdapter implements HttpClientAdapter {
  final Future<ResponseBody> Function(RequestOptions options) fn;

  _MockAdapter(this.fn);

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) =>
      fn(options);
}

