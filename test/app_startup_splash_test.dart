import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ksub/ui/splash/app_startup_splash.dart';
import 'package:ksub/ui/widgets/ksub_logo.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('KsubLogoMark renders cleanly at launcher and splash sizes', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          backgroundColor: Color(0xFF0F1015),
          body: Column(
            children: [
              KsubLogoMark(size: 48, showGlow: false),
              KsubLogoMark(size: 112),
            ],
          ),
        ),
      ),
    );

    expect(find.byType(KsubLogoMark), findsNWidgets(2));
  });

  testWidgets(
    'AppStartupSplash holds splash during init then reveals home cleanly',
    (tester) async {
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final initCompleter = Completer<void>();

      await tester.pumpWidget(
        MaterialApp(
          home: AppStartupSplash(
            minDisplayDuration: const Duration(milliseconds: 200),
            exitDuration: const Duration(milliseconds: 150),
            onInitialize: () => initCompleter.future,
            homeBuilder: (_) => const Scaffold(
              body: Center(child: Text('HOME_READY')),
            ),
          ),
        ),
      );

      // Immediately displays logo & splash copy while init is still running.
      expect(find.byType(KsubLogoMark), findsOneWidget);
      expect(find.text('Ksub'), findsOneWidget);
      expect(find.text('HOME_READY'), findsNothing);

      initCompleter.complete();
      await tester.pump(const Duration(milliseconds: 220));
      await tester.pump(); // triggers endOfFrame exit
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('HOME_READY'), findsOneWidget);
      expect(find.text('Ksub'), findsNothing);
    },
  );
}
