import 'package:capsub_flutter/ui/player/dual_volume_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'DualVolumeSheet updates slider and percentages live inside modal bottom sheet',
    (tester) async {
      double latestOrig = 0.25;
      double latestAi = 1.0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () {
                  showModalBottomSheet<void>(
                    context: context,
                    builder: (_) => DualVolumeSheet(
                      originalVolume: latestOrig,
                      aiVolume: latestAi,
                      onOriginalVolumeChanged: (v) => latestOrig = v,
                      onAiVolumeChanged: (v) => latestAi = v,
                    ),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.text('25%'), findsOneWidget);
      expect(find.text('100%'), findsOneWidget);

      // Tap mute icon on AI volume -> toggles to 0%
      await tester.tap(find.byIcon(Icons.volume_down).last);
      await tester.pump();
      expect(latestAi, 0.0);
      expect(find.text('0%'), findsOneWidget);

      // Drag original video slider to the right -> value and label increase live
      final origSlider = find.byType(Slider).first;
      await tester.drag(origSlider, const Offset(120, 0));
      await tester.pump();

      expect(latestOrig, greaterThan(0.25));
      expect(
        tester.widget<Slider>(origSlider).value,
        closeTo(latestOrig, 0.0001),
      );
      expect(find.text('${(latestOrig * 100).toInt()}%'), findsOneWidget);
    },
  );

  testWidgets(
    'DualVolumeSheet voice tuning presets and reset update callbacks live',
    (tester) async {
      double latestPitch = 1.0;
      double latestWarmth = 0.0;
      double latestBrightness = 0.0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () {
                  showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => DualVolumeSheet(
                      originalVolume: 0.25,
                      aiVolume: 1.0,
                      voicePitch: latestPitch,
                      voiceWarmth: latestWarmth,
                      voiceBrightness: latestBrightness,
                      onOriginalVolumeChanged: (_) {},
                      onAiVolumeChanged: (_) {},
                      onVoiceToneChanged: ({
                        required pitch,
                        required warmth,
                        required brightness,
                      }) {
                        latestPitch = pitch;
                        latestWarmth = warmth;
                        latestBrightness = brightness;
                      },
                    ),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Giảm the thé'));
      await tester.pump();
      expect(latestPitch, closeTo(0.94, 0.001));
      expect(latestWarmth, closeTo(0.45, 0.001));
      expect(latestBrightness, closeTo(-0.45, 0.001));

      await tester.tap(find.text('Đặt lại'));
      await tester.pump();
      expect(latestPitch, 1.0);
      expect(latestWarmth, 0.0);
      expect(latestBrightness, 0.0);
    },
  );
}

