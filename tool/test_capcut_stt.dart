// ignore_for_file: avoid_print

import 'dart:io';

import 'package:capsub_flutter/data/api/capcut_stt_client.dart';
import 'package:capsub_flutter/data/api/capcut_vod_uploader.dart';
import 'package:capsub_flutter/data/model/device_config.dart';

void main(List<String> args) async {
  if (args.isEmpty) {
    print('================================================================');
    print(' CÔNG CỤ TEST KIỂM THỬ TẠO PHỤ ĐỀ SRT TRỰC TIẾP TỪ CAPCUT CLOUD');
    print('================================================================');
    print('Cách dùng:');
    print('  dart run tool/test_capcut_stt.dart <duong_dan_file_audio> [ngon_ngu_nguon] [ngon_ngu_dich]');
    print('');
    print('Ví dụ:');
    print('  dart run tool/test_capcut_stt.dart "C:/test/sample.m4a" zh vi');
    print('  dart run tool/test_capcut_stt.dart "C:/test/sample.mp3"');
    print('================================================================');
    exit(0);
  }

  final filePath = args[0];
  final sourceLang = args.length > 1 ? args[1] : 'zh';
  final targetLang = args.length > 2 ? args[2] : 'vi';
  final file = File(filePath);

  if (!await file.exists()) {
    print('LỖI: Tệp không tồn tại: $filePath');
    exit(1);
  }

  final fileSizeMb = (await file.length()) / (1024 * 1024);
  print('-> Tệp audio: ${file.path} (${fileSizeMb.toStringAsFixed(2)} MB)');
  print('-> Ngôn ngữ nhận diện: $sourceLang -> $targetLang');

  final device = DeviceConfig().randomize();
  print('-> Đã tạo Device ID ảo: ${device.deviceId}');

  // 1. Upload VOD
  print('-> [1/2] Đang tải lên CapCut Cloud VOD...');
  final uploader = CapCutVodUploader(device: device);
  final uploadResult = await uploader.uploadFile(
    file,
    progressCallback: (pct, msg) {
      stdout.write('\r   Tải lên: ${(pct * 100).toStringAsFixed(1)}% - $msg');
    },
  );
  print('\n-> Tải lên thành công! VID: ${uploadResult.vid}, MD5: ${uploadResult.md5}');

  // 2. Nhận diện giọng nói STT
  print('-> [2/2] Đang yêu cầu CapCut Cloud nhận diện giọng nói (STT)...');
  final sttClient = CapCutSttClient(device: device);
  final doc = await sttClient.transcribeAudio(
    audioVid: uploadResult.vid,
    audioMd5: uploadResult.md5,
    durationMs: 0,
    language: sourceLang,
    useTranslation: true,
    translationLanguage: targetLang,
    progressCallback: (pct, msg) {
      stdout.write('\r   Xử lý STT: $msg');
    },
  );
  print('\n-> Hoàn tất nhận diện giọng nói!');
  print('-> Tổng số câu phụ đề tạo được: ${doc.items.length}');

  if (doc.items.isEmpty) {
    print('CẢNH BÁO: CapCut không tìm thấy câu thoại nào trong file này.');
    exit(0);
  }

  // Xuất file SRT
  final outSrtPath = '${file.parent.path}/${file.uri.pathSegments.last.split('.').first}_test.srt';
  final srtContent = doc.toSrtString();
  await File(outSrtPath).writeAsString(srtContent);
  print('-> Đã lưu tệp phụ đề SRT: $outSrtPath\n');

  print('--- [5 CÂU ĐẦU TIÊN CỦA BẢN PHỤ ĐỀ] ---');
  for (var i = 0; i < doc.items.length && i < 5; i++) {
    final item = doc.items[i];
    final startSec = (item.startMs / 1000).toStringAsFixed(3);
    final endSec = (item.endMs / 1000).toStringAsFixed(3);
    print('#${item.id} [${startSec}s -> ${endSec}s]');
    print('   Gốc : ${item.originalText}');
    if (item.translatedText.isNotEmpty) {
      print('   Dịch: ${item.translatedText}');
    }
  }

  if (doc.items.length > 5) {
    print('...\n--- [CÂU CUỐI CÙNG] ---');
    final last = doc.items.last;
    final startSec = (last.startMs / 1000).toStringAsFixed(3);
    final endSec = (last.endMs / 1000).toStringAsFixed(3);
    print('#${last.id} [${startSec}s -> ${endSec}s]');
    print('   Gốc : ${last.originalText}');
    if (last.translatedText.isNotEmpty) {
      print('   Dịch: ${last.translatedText}');
    }
  }
}
