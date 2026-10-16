// Optional visual review: flutter test --no-pub tool/preview_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show ImageByteFormat;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_iperf/app.dart';
import 'package:lan_iperf/discovery.dart';
import 'package:lan_iperf/model.dart';
import 'package:lan_iperf/latency_model.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final file = File(r'C:\Windows\Fonts\msyh.ttc');
    if (file.existsSync()) {
      final font = ByteData.sublistView(await file.readAsBytes());
      for (final family in ['Ahem', 'Roboto', 'Segoe UI']) {
        await (FontLoader(family)..addFont(Future.value(font))).load();
      }
    }
    final icons = File(
      '.tools/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    );
    if (icons.existsSync()) {
      await (FontLoader('MaterialIcons')..addFont(
            Future.value(ByteData.sublistView(await icons.readAsBytes())),
          ))
          .load();
    }
  });
  for (final width in [1280.0, 390.0]) {
    testWidgets('render preview $width', (tester) async {
      const device = Device('书房电脑', '192.168.1.20', 5201);
      final result = TestResult(
        const TestConfig(device: device),
        {
          'intervals': [
            for (var i = 0; i < 10; i++)
              {
                'sum_bidir_reverse': {
                  'end': i + 1,
                  'bits_per_second': (780 + i * 5) * 1000000,
                },
                'sum': {
                  'end': i + 1,
                  'bits_per_second':
                      [820, 910, 930, 915, 945, 940, 925, 950, 935, 943][i] *
                      1000000,
                },
              },
          ],
          'end': {
            'sum_received': {'bits_per_second': 931000000},
            'sum_received_bidir_reverse': {'bits_per_second': 810000000},
            'sum_sent': {'retransmits': 3},
          },
        },
        latencySamples: [
          for (var i = 0; i < 100; i++)
            LatencySample((i + 1) / 10, 2.0 + (i % 7) * .12),
        ],
        at: DateTime(2026, 10, 16, 19, 0),
      );
      // This optional renderer is executed by flutter test, outside test/.
      // ignore: invalid_use_of_visible_for_testing_member
      SharedPreferences.setMockInitialValues({
        'devices': jsonEncode([device.toJson()]),
        'history': jsonEncode([result.toJson()]),
      });
      await tester.binding.setSurfaceSize(Size(width, 860));
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(key: key, child: const LanIperfApp()),
      );
      await tester.pumpAndSettle();
      final record = find.textContaining('书房电脑 · ↑');
      await tester.ensureVisible(record);
      await tester.tap(record);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('吞吐量曲线'));
      await tester.pumpAndSettle();
      if (width > 500) {
        tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position
            .jumpTo(0);
        await tester.pumpAndSettle();
      }
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final png = await image.toByteData(format: ImageByteFormat.png);
        await Directory('docs').create();
        await File(
          'docs/${width > 500 ? 'desktop' : 'mobile'}-preview.png',
        ).writeAsBytes(png!.buffer.asUint8List());
        image.dispose();
      });
      expect(tester.takeException(), isNull);
      await tester.binding.setSurfaceSize(null);
    });
  }
  testWidgets('render device discovery with example endpoints', (tester) async {
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      NetworkDiscovery.channel,
      (_) async => [
        {
          'name': 'Wi-Fi',
          'address': '192.168.1.20',
          'prefix': 24,
          'preferred': true,
        },
      ],
    );
    await tester.binding.setSurfaceSize(const Size(1280, 860));
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: LanIperfApp(
          discoveryScannerFactory: () => LanScanner(
            probe: (host, port, timeout) async =>
                host == '192.168.1.21' || host == '192.168.1.35',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('搜索局域网设备'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始搜索'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final png = await image.toByteData(format: ImageByteFormat.png);
      await File(
        'docs/discovery-preview.png',
      ).writeAsBytes(png!.buffer.asUint8List());
      image.dispose();
    });
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      NetworkDiscovery.channel,
      null,
    );
    await tester.binding.setSurfaceSize(null);
  });
}
