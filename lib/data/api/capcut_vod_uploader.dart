import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:convert/convert.dart' as convert_pkg;
import 'package:crypto/crypto.dart' as crypto;

import '../model/device_config.dart';
import '../model/upload_result.dart';
import 'capcut_signer.dart';

class CapCutVodUploader {
  final DeviceConfig device;
  final Dio dio;

  CapCutVodUploader({DeviceConfig? device, Dio? dio})
    : device = device ?? DeviceConfig(),
      dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 60),
              receiveTimeout: const Duration(seconds: 120),
              sendTimeout: const Duration(seconds: 120),
            ),
          );

  Future<UploadResult> uploadFile(
    File file, {
    void Function(double progress, String message)? progressCallback,
    bool Function()? isCancelled,
  }) async {
    if (!await file.exists()) {
      throw Exception('Không tìm thấy tệp: ${file.path}');
    }

    final fileSize = await file.length();
    final localMd5 = await _fileMd5(file);
    _throwIfCancelled(isCancelled);

    // 1. Upload Sign
    progressCallback?.call(0.05, 'Đang xác thực bảo mật VOD...');
    final signReq = _buildUploadSignRequest();
    final signResp = await dio.post<String>(
      signReq['url'] as String,
      data: signReq['body'],
      options: Options(
        headers: signReq['headers'] as Map<String, dynamic>,
        responseType: ResponseType.plain,
      ),
    );

    final signJson = jsonDecode(signResp.data ?? '{}') as Map<String, dynamic>;
    final creds = signJson['data'] as Map<String, dynamic>?;
    if (creds == null) {
      throw Exception('Lỗi upload_sign: ${signResp.data}');
    }

    final domain = creds['domain'] as String? ?? '';
    final accessKeyId = creds['access_key_id'] as String? ?? '';
    final secretAccessKey = creds['secret_access_key'] as String? ?? '';
    final sessionToken = creds['session_token'] as String? ?? '';
    final spaceName = creds['space_name'] as String? ?? '';

    // 2. Apply Upload Inner
    progressCallback?.call(0.15, 'Đang xin cấp phép đường truyền tải lên...');
    final applyUrl =
        'https://$domain/top/v1?Action=ApplyUploadInner&SpaceName=$spaceName&UseQuic=false&Version=2020-11-19&device_platform=mac';
    final utcDates = CapCutSigner.getUtcDatesForVod();
    final amzDate = utcDates['iso']!;
    final httpDate = utcDates['http']!;

    final applyAuth = CapCutSigner.aws4Authorization(
      method: 'GET',
      url: applyUrl,
      body: [],
      accessKeyId: accessKeyId,
      secretAccessKey: secretAccessKey,
      sessionToken: sessionToken,
      amzDate: amzDate,
    );

    final applyResp = await dio.get<String>(
      applyUrl,
      options: Options(
        headers: {
          'Authorization': applyAuth,
          'Date': httpDate,
          'X-Amz-Date': amzDate,
          'X-Amz-Expires': '31536000',
          'X-Amz-Security-Token': sessionToken,
          'accept-encoding': 'identity',
          'store-country-code': device.loc.toLowerCase(),
          'tdid': device.tdid,
          'pf': device.pf,
        },
        responseType: ResponseType.plain,
      ),
    );

    final applyJson =
        jsonDecode(applyResp.data ?? '{}') as Map<String, dynamic>;
    final resultObj = applyJson['Result'] as Map<String, dynamic>?;
    if (resultObj == null) {
      throw Exception('Lỗi ApplyUploadInner: ${applyResp.data}');
    }

    final uploadNodes =
        resultObj['InnerUploadAddress']?['UploadNodes'] as List<dynamic>?;
    final firstNode = uploadNodes?.isNotEmpty == true
        ? uploadNodes![0] as Map<String, dynamic>
        : null;
    if (firstNode == null) throw Exception('Không tìm thấy UploadNode');

    final storeInfos = firstNode['StoreInfos'] as List<dynamic>?;
    final firstStore = storeInfos?.isNotEmpty == true
        ? storeInfos![0] as Map<String, dynamic>
        : null;
    if (firstStore == null) throw Exception('Không tìm thấy StoreInfos');

    final uploadHost = firstNode['UploadHost'] as String? ?? '';
    final sessionKey = firstNode['SessionKey'] as String? ?? '';
    final defaultVid = firstNode['Vid'] as String? ?? '';
    final storeUri = firstStore['StoreUri'] as String? ?? '';
    final uploadId = firstStore['UploadID'] as String? ?? '';
    final uploadAuth = firstStore['Auth'] as String? ?? '';

    // 3. Transfer binary in 5MB chunks
    const chunkSize = 5 * 1024 * 1024; // 5MB
    final partCrcs = <String>[];
    final totalParts = ((fileSize + chunkSize - 1) ~/ chunkSize).clamp(
      1,
      999999,
    );

    final raf = await file.open(mode: FileMode.read);
    try {
      var partIndex = 0;
      var remaining = fileSize;

      while (remaining > 0) {
        _throwIfCancelled(isCancelled);
        final toRead = remaining > chunkSize ? chunkSize : remaining;
        final chunkData = await raf.read(toRead);
        if (chunkData.isEmpty) break;

        final chunkCrc32 = CapCutSigner.crc32Hex(chunkData);
        partCrcs.add('$partIndex:$chunkCrc32');

        final transferUrl =
            'https://$uploadHost/upload/v1/$storeUri?uploadid=$uploadId&part_number=$partIndex&phase=transfer';
        final nowUtc = CapCutSigner.getUtcDatesForVod()['http']!;

        final transferResp = await dio.post<dynamic>(
          transferUrl,
          data: Stream.fromIterable([chunkData]),
          options: Options(
            headers: {
              'Authorization': uploadAuth,
              'Date': nowUtc,
              'X-Upload-Content-CRC32': chunkCrc32,
              'store-country-code': device.loc.toLowerCase(),
              'tdid': device.tdid,
              'pf': device.pf,
              'Content-Type': 'application/octet-stream',
              'Content-Length': chunkData.length.toString(),
            },
          ),
        );

        if (transferResp.statusCode != 200) {
          throw Exception(
            'Lỗi tải phân đoạn $partIndex: HTTP ${transferResp.statusCode}',
          );
        }

        partIndex++;
        remaining -= chunkData.length;
        final uploadPct = 0.20 + (partIndex / totalParts) * 0.60;
        progressCallback?.call(
          uploadPct,
          'Đang tải lên CapCut Cloud: ${(uploadPct * 100).toInt()}% ($partIndex/$totalParts)',
        );
      }
    } finally {
      await raf.close();
    }

    // 4. Finish upload
    final finishUrl =
        'https://$uploadHost/upload/v1/$storeUri?uploadmode=part&phase=finish&uploadid=$uploadId';
    final finishBodyText = partCrcs.join(',');
    final finishNowUtc = CapCutSigner.getUtcDatesForVod()['http']!;

    final finishResp = await dio.post<dynamic>(
      finishUrl,
      data: finishBodyText,
      options: Options(
        headers: {
          'Authorization': uploadAuth,
          'Date': finishNowUtc,
          'store-country-code': device.loc.toLowerCase(),
          'tdid': device.tdid,
          'pf': device.pf,
          'Content-Type': 'text/plain',
        },
      ),
    );

    if (finishResp.statusCode != 200) {
      throw Exception(
        'Lỗi hoàn tất tải lên (finish): HTTP ${finishResp.statusCode}',
      );
    }

    // 5. Commit Upload Inner
    progressCallback?.call(0.85, 'Đang xác nhận lưu trữ tệp tin...');
    final commitUrl =
        'https://$domain/top/v1?Action=CommitUploadInner&SpaceName=$spaceName&Version=2020-11-19&device_platform=mac';
    final commitBody = jsonEncode({
      'Functions': [
        {
          'Input': {'SnapshotTime': 0.0},
          'Name': 'Snapshot',
        },
      ],
      'SessionKey': sessionKey,
    });

    final commitDates = CapCutSigner.getUtcDatesForVod();
    final commitAmzDate = commitDates['iso']!;
    final commitHttpDate = commitDates['http']!;
    final commitAuth = CapCutSigner.aws4Authorization(
      method: 'POST',
      url: commitUrl,
      body: utf8.encode(commitBody),
      accessKeyId: accessKeyId,
      secretAccessKey: secretAccessKey,
      sessionToken: sessionToken,
      amzDate: commitAmzDate,
    );

    final commitResp = await dio.post<String>(
      commitUrl,
      data: commitBody,
      options: Options(
        headers: {
          'Authorization': commitAuth,
          'Date': commitHttpDate,
          'X-Amz-Date': commitAmzDate,
          'X-Amz-Expires': '31536000',
          'X-Amz-Security-Token': sessionToken,
          'store-country-code': device.loc.toLowerCase(),
          'tdid': device.tdid,
          'pf': device.pf,
          'Content-Type': 'application/json',
        },
        responseType: ResponseType.plain,
      ),
    );

    final commitJson =
        jsonDecode(commitResp.data ?? '{}') as Map<String, dynamic>;
    final results = commitJson['Result']?['Results'] as List<dynamic>?;
    final commitResult = results?.isNotEmpty == true
        ? results![0] as Map<String, dynamic>
        : null;

    final finalVid = commitResult?['Vid'] as String? ?? defaultVid;
    final videoMeta = commitResult?['VideoMeta'] as Map<String, dynamic>?;
    final durationSec = (videoMeta?['Duration'] as num?)?.toDouble() ?? 0.0;
    final finalMd5 = videoMeta?['Md5'] as String? ?? localMd5;

    progressCallback?.call(0.95, 'Tải lên thành công!');

    return UploadResult(
      vid: finalVid,
      md5: finalMd5,
      durationMs: (durationSec * 1000).toInt(),
      size: fileSize,
      storeUri: storeUri,
    );
  }

  Future<String> _fileMd5(File file) async {
    final output = convert_pkg.AccumulatorSink<crypto.Digest>();
    final input = crypto.md5.startChunkedConversion(output);
    await for (final chunk in file.openRead()) {
      input.add(chunk);
    }
    input.close();
    return output.events.single.toString();
  }

  void _throwIfCancelled(bool Function()? isCancelled) {
    if (isCancelled?.call() == true) {
      throw StateError('Đã huỷ tác vụ');
    }
  }

  Map<String, dynamic> _buildUploadSignRequest() {
    final body = jsonEncode({
      'biz': 'cc_pc_text_recognize',
      'key_version': 'v5',
    });
    const path = '/lv/v1/upload_sign';
    final queryMap = device.toQueryMap(includeRegion: false);
    final queryParams = queryMap.entries
        .map(
          (e) =>
              '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}',
        )
        .join('&');
    final fullUrl = '${CapCutSigner.baseUrl}$path?$queryParams';

    final headers = CapCutSigner.buildBaseHeaders(device, body, appid: true);
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
