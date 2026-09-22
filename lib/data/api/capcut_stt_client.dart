import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

import '../model/device_config.dart';
import '../model/subtitle_document.dart';
import '../model/subtitle_item.dart';
import 'capcut_signer.dart';

class CapCutSttClient {
  final DeviceConfig device;
  final Dio dio;

  CapCutSttClient({DeviceConfig? device, Dio? dio})
    : device = device ?? DeviceConfig(),
      dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 30),
              receiveTimeout: const Duration(seconds: 60),
            ),
          );

  Future<SubtitleDocument> transcribeAudio({
    required String audioVid,
    required String audioMd5,
    required int durationMs,
    String language = 'zh-CN',
    bool useTranslation = false,
    String translationLanguage = 'vi-VN',
    int timeOffsetMs = 0,
    bool Function()? isCancelled,
    void Function(double progress, String message)? progressCallback,
  }) async {
    // 1. Gửi request tạo Task STT
    progressCallback?.call(
      0.10,
      useTranslation
          ? 'Đang gửi tác vụ STT & Dịch thuật CapCut...'
          : 'Đang gửi tác vụ nhận diện giọng nói...',
    );

    final newReq = _buildCreateSttRequest(
      audioVid: audioVid,
      audioMd5: audioMd5,
      durationMs: durationMs,
      language: language,
      useTranslation: useTranslation,
      translationLanguage: translationLanguage,
    );

    final newResp = await dio.post<String>(
      newReq['url'] as String,
      data: newReq['body'],
      options: Options(
        headers: newReq['headers'] as Map<String, dynamic>,
        responseType: ResponseType.plain,
      ),
    );

    final newJson = jsonDecode(newResp.data ?? '{}') as Map<String, dynamic>;
    final tasks = newJson['data']?['tasks'] as List<dynamic>?;
    final taskItem = tasks?.isNotEmpty == true
        ? tasks![0] as Map<String, dynamic>
        : null;
    if (taskItem == null) {
      throw Exception('Không nhận được STT task: ${newResp.data}');
    }

    final taskId = taskItem['id'] as String? ?? '';
    final token = taskItem['token'] as String? ?? '';
    if (taskId.isEmpty || token.isEmpty) {
      throw Exception('Thiếu task id hoặc token: ${newResp.data}');
    }

    // 2. Polling kiểm tra kết quả (tối đa 5 phút)
    final startTime = DateTime.now().millisecondsSinceEpoch;

    while (DateTime.now().millisecondsSinceEpoch - startTime < 300000) {
      if (isCancelled?.call() == true) {
        throw StateError('Đã huỷ tác vụ');
      }

      final elapsedSec =
          (DateTime.now().millisecondsSinceEpoch - startTime) ~/ 1000;
      final progressPct = (0.20 + (elapsedSec / 60.0) * 0.70).clamp(0.20, 0.95);
      progressCallback?.call(
        progressPct,
        'CapCut Cloud đang xử lý... (${elapsedSec}s)',
      );

      await Future<void>.delayed(const Duration(seconds: 2));
      if (isCancelled?.call() == true) {
        throw StateError('Đã huỷ tác vụ');
      }

      final queryReq = _buildQuerySttRequest(taskId: taskId, token: token);
      final queryResp = await dio.post<String>(
        queryReq['url'] as String,
        data: queryReq['body'],
        options: Options(
          headers: queryReq['headers'] as Map<String, dynamic>,
          responseType: ResponseType.plain,
        ),
      );

      final queryJson =
          jsonDecode(queryResp.data ?? '{}') as Map<String, dynamic>;
      final queryTasks = queryJson['data']?['tasks'] as List<dynamic>?;
      final currentTask = queryTasks?.isNotEmpty == true
          ? queryTasks![0] as Map<String, dynamic>
          : null;
      if (currentTask == null) continue;

      final status = (currentTask['status'] as String? ?? '').toLowerCase();
      if (status == 'success' || status == 'succeed') {
        progressCallback?.call(1.0, 'Nhận diện giọng nói thành công!');
        return _extractSubtitlesFromPayload(currentTask, timeOffsetMs);
      } else if (status == 'failed') {
        throw Exception(
          'CapCut báo lỗi xử lý thất bại (file không có âm thanh hoặc định dạng không hợp lệ).',
        );
      }
    }

    throw Exception('Quá thời gian chờ phản hồi STT (Timeout 5 phút).');
  }

  SubtitleDocument _extractSubtitlesFromPayload(
    Map<String, dynamic> taskJson,
    int timeOffsetMs,
  ) {
    final payloadElement = taskJson['payload'];
    if (payloadElement == null) return SubtitleDocument();

    Map<String, dynamic> payloadObj;
    if (payloadElement is String) {
      payloadObj = jsonDecode(payloadElement) as Map<String, dynamic>;
    } else {
      payloadObj = payloadElement as Map<String, dynamic>;
    }

    final rawUtterances = payloadObj['utterances'] as List<dynamic>? ?? [];
    final list = <SubtitleItem>[];

    for (var i = 0; i < rawUtterances.length; i++) {
      final item = rawUtterances[i] as Map<String, dynamic>;
      final originalText = item['text'] as String? ?? '';
      final translationText = item['translation_text'] as String? ?? '';

      final startMs =
          (int.tryParse(item['start_time']?.toString() ?? '0') ?? 0) +
          timeOffsetMs;
      final endMs =
          (int.tryParse(item['end_time']?.toString() ?? '0') ?? 0) +
          timeOffsetMs;

      final mainText = originalText.isNotEmpty ? originalText : translationText;
      if (mainText.trim().isNotEmpty) {
        list.add(
          SubtitleItem(
            id: i + 1,
            startMs: startMs,
            endMs: endMs,
            originalText: mainText,
            translatedText: translationText,
          ),
        );
      }
    }

    return SubtitleDocument(list);
  }

  Map<String, dynamic> _buildCreateSttRequest({
    required String audioVid,
    required String audioMd5,
    required int durationMs,
    required String language,
    required bool useTranslation,
    required String translationLanguage,
  }) {
    const uuid = Uuid();
    final clientReqId = uuid.v4();
    final bindId = uuid.v4().toUpperCase();
    final contextId = uuid.v4();

    final capJsonObj = {
      'adjust_endtime': 200,
      'audio': audioVid,
      'audio_type': 'vid',
      'caption_type': 0,
      'client_request_id': clientReqId,
      'duration': durationMs,
      'enable_cache': true,
      'enter_from': 'asr',
      'language': language,
      'max_lines': 1,
      'md5': audioMd5,
      'pack_options': {'need_attribute': true},
      'songs_info': [
        {
          'end_time': (durationMs - 10).clamp(0, 999999999),
          'id': '',
          'start_time': 0,
        },
      ],
      'translation_language': translationLanguage,
      'use_translation': useTranslation,
      'words_per_line': 15,
    };

    final payloadObj = {'cap_json': capJsonObj};

    final body = jsonEncode({
      'bind_id': bindId,
      'can_queue': true,
      'enter_from': 'asr',
      'tasks': [
        {
          'context': contextId,
          'payload': jsonEncode(payloadObj),
          'req_key': 'cc_audio_subtitle_asr',
          'task_version': 'v3',
        },
      ],
    });

    const path = '/lv/v1/common_task/new';
    const babi =
        '{"feature_entrance":"editor","feature_entrance_detail":"editor-elements-captions-subtitle_recognition","feature_key":"subtitle_recognition","scenario":"video_editor"}';

    final queryMap = Map<String, String>.from(
      device.toQueryMap(includeRegion: true),
    )..['babi_param'] = babi;
    final queryParams = queryMap.entries
        .map(
          (e) =>
              '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}',
        )
        .join('&');
    final fullUrl = '${CapCutSigner.baseUrl}$path?$queryParams';

    final headers = CapCutSigner.buildBaseHeaders(device, body, appid: false);
    final sign = CapCutSigner.makeSignHeader(
      fullUrl,
      device.appvr,
      headers['device-time'] ?? '',
      device.tdid,
    );
    headers['sign'] = sign;

    return {'url': fullUrl, 'headers': headers, 'body': body};
  }

  Map<String, dynamic> _buildQuerySttRequest({
    required String taskId,
    required String token,
  }) {
    final body = jsonEncode({
      'tasks': [
        {
          'bind_id': '',
          'id': taskId,
          'req_key': 'cc_audio_subtitle_asr',
          'task_version': 'v3',
          'token': token,
        },
      ],
    });

    const path = '/lv/v1/common_task/query';
    final queryMap = device.toQueryMap(includeRegion: false);
    final queryParams = queryMap.entries
        .map(
          (e) =>
              '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}',
        )
        .join('&');
    final fullUrl = '${CapCutSigner.baseUrl}$path?$queryParams';

    final headers = CapCutSigner.buildBaseHeaders(device, body, appid: false);
    final sign = CapCutSigner.makeSignHeader(
      fullUrl,
      device.appvr,
      headers['device-time'] ?? '',
      device.tdid,
    );
    headers['sign'] = sign;

    return {'url': fullUrl, 'headers': headers, 'body': body};
  }
}
