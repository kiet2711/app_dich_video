import 'package:flutter_test/flutter_test.dart';
import 'package:capsub_flutter/data/model/subtitle_document.dart';

void main() {
  group('SubtitleDocument & SubtitleItem tests', () {
    const sampleSrt = """1
00:00:01,000 --> 00:00:03,500
Xin chào các bạn

2
00:00:04,000 --> 00:00:07,200
Chào mừng đến với CapSub Studio
""";

    test('SubtitleDocument SRT parse and export test', () {
      final doc = SubtitleDocument.parseSrt(sampleSrt);
      expect(doc.size, equals(2));
      expect(doc.items[0].startMs, equals(1000));
      expect(doc.items[0].endMs, equals(3500));
      expect(doc.items[0].originalText, equals('Xin chào các bạn'));

      expect(doc.items[1].startMs, equals(4000));
      expect(doc.items[1].endMs, equals(7200));
      expect(
        doc.items[1].originalText,
        equals('Chào mừng đến với CapSub Studio'),
      );

      final exported = doc.toSrtString();
      expect(exported.contains('00:00:01,000 --> 00:00:03,500'), isTrue);
      expect(exported.contains('00:00:04,000 --> 00:00:07,200'), isTrue);
    });

    test('Binary search getActiveItem', () {
      final doc = SubtitleDocument.parseSrt(sampleSrt);

      // Before first subtitle
      expect(doc.getActiveItem(500), isNull);

      // Inside first subtitle
      final active1 = doc.getActiveItem(2000);
      expect(active1, isNotNull);
      expect(active1!.id, equals(1));
      expect(active1.originalText, equals('Xin chào các bạn'));

      // Gap between subtitles
      expect(doc.getActiveItem(3700), isNull);

      // Inside second subtitle
      final active2 = doc.getActiveItem(5000);
      expect(active2, isNotNull);
      expect(active2!.id, equals(2));

      // After last subtitle
      expect(doc.getActiveItem(10000), isNull);
    });

    test('Serialization to/from JSON', () {
      final doc = SubtitleDocument.parseSrt(sampleSrt);
      final jsonMap = doc.toJson();
      final recovered = SubtitleDocument.fromJson(jsonMap);

      expect(recovered.size, equals(2));
      expect(recovered.items[0].originalText, equals(doc.items[0].originalText));
      expect(recovered.items[1].endMs, equals(doc.items[1].endMs));
    });

    test('ASS Subtitle generation', () {
      final doc = SubtitleDocument.parseSrt(sampleSrt);
      final ass = doc.toAssString();
      expect(ass.contains('[Script Info]'), isTrue);
      expect(ass.contains('[V4+ Styles]'), isTrue);
      expect(ass.contains('Style: BlackBox'), isTrue);
      expect(ass.contains('Dialogue: 0,0:00:01.00,0:00:03.50,BlackBox,,0,0,0,,Xin chào các bạn'), isTrue);
    });

    test('Chinese bilingual separation logic', () {
      const bilingualBlock = "你好世界\nXin chào thế giới";
      final split = SubtitleDocument.splitChineseSourceAndTranslation(bilingualBlock);
      expect(split, isNotNull);
      expect(split!['source'], equals('你好世界'));
      expect(split['translation'], equals('Xin chào thế giới'));
    });
  });
}
