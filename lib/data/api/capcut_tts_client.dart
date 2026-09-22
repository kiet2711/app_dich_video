import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

import '../model/device_config.dart';
import 'capcut_signer.dart';

enum TtsErrorKind {
  parametersModified,
  taskFailed,
  timeout,
  network,
  invalidAudio,
  invalidResponse,
}

class CapCutTtsException implements IOException {
  final TtsErrorKind kind;
  final String message;
  final Object? cause;

  CapCutTtsException(this.kind, this.message, [this.cause]);

  @override
  String toString() => 'CapCutTtsException($kind): $message';
}

class CapCutTtsClient {
  final DeviceConfig device;
  final Dio dio;

  CapCutTtsClient({DeviceConfig? device, Dio? dio})
    : device = device ?? DeviceConfig(),
      dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 25),
            ),
          );

  Future<File> generateSpeechToFile({
    required String text,
    required String voiceType,
    required String resourceId,
    String rate = '1.0',
    required File destFile,
    int timeoutMs = 20000,
    int maxRetries = 3,
  }) async {
    final cleanText = text.trim();
    if (cleanText.isEmpty) {
      throw ArgumentError('Nội dung câu thoại không được để trống');
    }

    if (!await destFile.parent.exists()) {
      await destFile.parent.create(recursive: true);
    }
    final partFile = File('${destFile.path}.part');
    if (await partFile.exists()) await partFile.delete();

    Object? lastException;
    for (var attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        await _executeGenerateSpeech(
          cleanText: cleanText,
          voiceType: voiceType,
          resourceId: resourceId,
          rate: rate,
          destFile: partFile,
          timeoutMs: timeoutMs,
        );

        if (await partFile.length() < 100) {
          throw CapCutTtsException(
            TtsErrorKind.invalidAudio,
            'File âm thanh nhận được quá nhỏ',
          );
        }

        if (await destFile.exists()) await destFile.delete();
        await partFile.rename(destFile.path);
        return destFile;
      } catch (e) {
        lastException = e;
        if (await partFile.exists()) await partFile.delete();
        if (attempt < maxRetries) {
          device.randomize();
          final extraDelay =
              (e is CapCutTtsException &&
                  e.kind == TtsErrorKind.parametersModified)
              ? 600
              : 0;
          await Future<void>.delayed(
            Duration(milliseconds: 700 * attempt + extraDelay),
          );
        }
      }
    }

    throw lastException ??
        CapCutTtsException(
          TtsErrorKind.invalidResponse,
          'Tạo TTS thất bại sau $maxRetries lần thử',
        );
  }

  Future<File> _executeGenerateSpeech({
    required String cleanText,
    required String voiceType,
    required String resourceId,
    required String rate,
    required File destFile,
    required int timeoutMs,
  }) async {
    final bindId = const Uuid().v4();
    final createReq = _buildCreateTtsRequest(
      cleanText,
      voiceType,
      resourceId,
      rate,
      bindId,
    );

    final createResp = await dio.post<String>(
      createReq['url'] as String,
      data: createReq['body'],
      options: Options(
        headers: createReq['headers'] as Map<String, dynamic>,
        responseType: ResponseType.plain,
      ),
    );

    final createJsonStr = createResp.data ?? '{}';
    final createJson = jsonDecode(createJsonStr) as Map<String, dynamic>;
    _throwIfApiRejected(createJsonStr, createJson);

    final tasks = createJson['data']?['tasks'] as List<dynamic>?;
    final taskItem = tasks?.isNotEmpty == true
        ? tasks![0] as Map<String, dynamic>
        : null;
    if (taskItem == null) {
      throw CapCutTtsException(
        TtsErrorKind.invalidResponse,
        'CapCut không trả task TTS: $createJsonStr',
      );
    }

    final taskId = taskItem['id'] as String? ?? '';
    final token = taskItem['token'] as String? ?? '';
    if (taskId.isEmpty || token.isEmpty) {
      throw CapCutTtsException(
        TtsErrorKind.invalidResponse,
        'Thiếu task id hoặc token: $createJsonStr',
      );
    }

    // Polling nhận kết quả
    final startTime = DateTime.now().millisecondsSinceEpoch;
    while (DateTime.now().millisecondsSinceEpoch - startTime < timeoutMs) {
      await Future<void>.delayed(const Duration(milliseconds: 350));

      final queryReq = _buildQueryTtsRequest(taskId, token, bindId);
      final queryResp = await dio.post<String>(
        queryReq['url'] as String,
        data: queryReq['body'],
        options: Options(
          headers: queryReq['headers'] as Map<String, dynamic>,
          responseType: ResponseType.plain,
        ),
      );

      final queryJsonStr = queryResp.data ?? '{}';
      final queryJson = jsonDecode(queryJsonStr) as Map<String, dynamic>;
      _throwIfApiRejected(queryJsonStr, queryJson);

      final queryTasks = queryJson['data']?['tasks'] as List<dynamic>?;
      final currentTask = queryTasks?.isNotEmpty == true
          ? queryTasks![0] as Map<String, dynamic>
          : null;
      if (currentTask == null) continue;

      final status = (currentTask['status'] as String? ?? '').toLowerCase();
      if (status == 'success' || status == 'succeed') {
        await _downloadAudioFromTask(currentTask, destFile);
        return destFile;
      } else if (status == 'failed') {
        final errMsg =
            currentTask['message'] as String? ??
            queryJson['message'] as String? ??
            'CapCut báo lỗi tổng hợp âm thanh';
        throw CapCutTtsException(
          TtsErrorKind.taskFailed,
          'TTS Task failed: $errMsg',
        );
      }
    }

    throw CapCutTtsException(
      TtsErrorKind.timeout,
      'TTS Task timeout sau ${timeoutMs ~/ 1000}s',
    );
  }

  void _throwIfApiRejected(String rawJson, Map<String, dynamic> json) {
    final ret = json['ret']?.toString();
    if (ret != null && ret.isNotEmpty && ret != '0') {
      final message =
          json['errmsg']?.toString() ??
          json['message']?.toString() ??
          'CapCut từ chối yêu cầu';
      final kind =
          (ret == '5001' ||
              message.toLowerCase().contains('parameters modified'))
          ? TtsErrorKind.parametersModified
          : TtsErrorKind.invalidResponse;
      throw CapCutTtsException(
        kind,
        'CapCut ret=$ret: $message. Phản hồi: ${rawJson.substring(0, rawJson.length.clamp(0, 300))}',
      );
    }
  }

  Future<void> _downloadAudioFromTask(
    Map<String, dynamic> taskObj,
    File destFile,
  ) async {
    String? audioUrl;
    String? audioBase64;

    final payloadStr = taskObj['payload'];
    if (payloadStr != null) {
      try {
        final payloadJson = payloadStr is String
            ? (jsonDecode(payloadStr) as Map<String, dynamic>)
            : (payloadStr as Map<String, dynamic>);
        final audioSubtitles = payloadJson['audio_subtitles'] as List<dynamic>?;
        if (audioSubtitles != null && audioSubtitles.isNotEmpty) {
          audioUrl = audioSubtitles[0]['speech_url'] as String?;
        }
        audioUrl ??=
            payloadJson['speech_url'] as String? ??
            payloadJson['video_url'] as String?;
        audioBase64 ??= payloadJson['audio'] as String?;

        final capJsonElement = payloadJson['cap_json'];
        if (capJsonElement != null) {
          final capJson = capJsonElement is String
              ? (jsonDecode(capJsonElement) as Map<String, dynamic>)
              : (capJsonElement as Map<String, dynamic>);
          audioUrl ??=
              capJson['speech_url'] as String? ??
              capJson['video_url'] as String?;
          audioBase64 ??= capJson['audio'] as String?;
        }
      } catch (_) {}
    }

    if (audioBase64 != null && audioBase64.isNotEmpty) {
      await destFile.writeAsBytes(base64Decode(audioBase64));
      return;
    }

    if (audioUrl != null && audioUrl.isNotEmpty) {
      final resp = await dio.get<List<int>>(
        audioUrl,
        options: Options(responseType: ResponseType.bytes),
      );
      if (resp.data != null) {
        await destFile.writeAsBytes(resp.data!);
        return;
      }
    }

    throw CapCutTtsException(
      TtsErrorKind.invalidAudio,
      'Không tìm thấy URL hoặc Base64 audio trong kết quả TTS',
    );
  }

  Map<String, dynamic> _buildCreateTtsRequest(
    String text,
    String voiceType,
    String resourceId,
    String rate,
    String bindId,
  ) {
    final ssml =
        '<speak><voice name="${_escapeXml(voiceType)}"><prosody rate="${_escapeXml(rate)}">${_escapeXml(text)}</prosody></voice></speak>';
    const extraInfo = '{"benefit_info":{}}';
    final sign = CapCutSigner.makeTtsPayloadSign(
      ssml,
      extraInfo,
      device.deviceId,
      device.aid,
    );

    final payloadObj = {
      'audio_subtitles': [
        {
          'app_id': device.aid,
          'device_id': device.deviceId,
          'extra_info': extraInfo,
          'rate': rate,
          'resource_id': resourceId,
          'sign': sign,
          'speaker': voiceType,
          'ssml': ssml,
          'text': text,
        },
      ],
    };

    final body = jsonEncode({
      'bind_id': bindId,
      'tasks': [
        {
          'payload': jsonEncode(payloadObj),
          'req_key': 'cc_audio_tts_stream',
          'task_version': 'v1',
        },
      ],
    });

    const path = '/lv/v1/common_task/new';
    final queryMap = device.toQueryMap(includeRegion: true);
    final queryParams = queryMap.entries
        .map(
          (e) =>
              '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}',
        )
        .join('&');
    final fullUrl = '${CapCutSigner.baseUrl}$path?$queryParams';

    final headers = CapCutSigner.buildBaseHeaders(device, body, appid: false);
    final signHeader = CapCutSigner.makeSignHeader(
      fullUrl,
      device.appvr,
      headers['device-time'] ?? '',
      device.tdid,
    );
    headers['sign'] = signHeader;

    return {'url': fullUrl, 'headers': headers, 'body': body};
  }

  String _escapeXml(String value) {
    return value
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }

  Map<String, dynamic> _buildQueryTtsRequest(
    String taskId,
    String token,
    String bindId,
  ) {
    final body = jsonEncode({
      'tasks': [
        {
          'bind_id': bindId,
          'id': taskId,
          'req_key': 'cc_audio_tts_stream',
          'task_version': 'v1',
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
    final signHeader = CapCutSigner.makeSignHeader(
      fullUrl,
      device.appvr,
      headers['device-time'] ?? '',
      device.tdid,
    );
    headers['sign'] = signHeader;

    return {'url': fullUrl, 'headers': headers, 'body': body};
  }
}
