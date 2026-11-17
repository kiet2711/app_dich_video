import 'dart:async';

import 'package:capsub_flutter/ui/splash/app_startup_splash.dart';
import 'package:capsub_flutter/ui/widgets/capsub_logo.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('CapSubLogoMark renders cleanly at launcher and splash sizes',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          backgroundColor: Color(0xFF0F1015),
          body: Column(
            children: [
              CapSubLogoMark(size: 48, showGlow: false),
              CapSubLogoMark(size: 112),
            ],
          ),
        ),
      ),
    );

    expect(find.byType(CapSubLogoMark), findsNWidgets(2));
  });

  testWidgets('AppStartupSplash holds splash during init then reveals home cleanly',
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
    expect(find.byType(CapSubLogoMark), findsOneWidget);
    expect(find.text('CapSub AI'), findsOneWidget);
    expect(find.text('HOME_READY'), findsNothing);

    initCompleter.complete();
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pump(); // triggers endOfFrame exit
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('HOME_READY'), findsOneWidget);
    expect(find.text('CapSub AI'), findsNothing);
  });
}

