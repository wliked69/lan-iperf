import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_iperf/discovery.dart';
import 'package:lan_iperf/app.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('selecting a discovered endpoint saves it and enables testing', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'listenPort': 5202});
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      NetworkDiscovery.channel,
      (_) async => [
        {'name': 'Wi-Fi', 'address': '192.168.50.2', 'prefix': 24},
      ],
    );
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpWidget(
      LanIperfApp(
        discoveryScannerFactory: () =>
            LanScanner(probe: (host, port, timeout) async => true),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('搜索局域网设备'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, '扫描网段'),
      '192.168.50.3/32',
    );
    await tester.tap(find.text('开始搜索'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('192.168.50.3:5201'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('发现的设备 192.168.50.3 · 192.168.50.3:5201'),
      findsWidgets,
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('listenPort'), 5201);
    expect(prefs.getBool('unifiedDefaultPortV1'), isTrue);
    expect(prefs.getString('selected'), '192.168.50.3:5201');
    expect(prefs.getString('devices'), contains('192.168.50.3'));
    final start = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '开始测速'),
    );
    expect(start.onPressed, isNotNull);
    expect(tester.takeException(), isNull);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      NetworkDiscovery.channel,
      null,
    );
    await tester.binding.setSurfaceSize(null);
  });
  testWidgets('discovery UI detects adapters and validates scan scope', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      NetworkDiscovery.channel,
      (_) async => [
        {'name': 'Wi-Fi', 'address': '192.168.50.2', 'prefix': 24},
      ],
    );
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpWidget(const LanIperfApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('搜索局域网设备'));
    await tester.pumpAndSettle();
    expect(find.text('Wi-Fi · 192.168.50.2/24'), findsWidgets);
    expect(find.text('192.168.50.0/24'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextFormField, '扫描网段'),
      '192.168.50.0/16',
    );
    await tester.tap(find.text('开始搜索'));
    await tester.pumpAndSettle();
    expect(find.text('扫描范围支持 /20–/32，每次最多 4094 个地址'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      NetworkDiscovery.channel,
      null,
    );
    await tester.binding.setSurfaceSize(null);
  });
  testWidgets('mobile UI allows adding and selecting a device', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpWidget(const LanIperfApp());
    await tester.pumpAndSettle();
    expect(find.text('选择目标设备'), findsOneWidget);
    await tester.tap(find.text('添加设备'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, '设备名称'), 'NAS');
    await tester.enterText(
      find.widgetWithText(TextFormField, 'IP 地址或主机名'),
      '192.168.1.20',
    );
    await tester.tap(find.text('保存并选择'));
    await tester.pumpAndSettle();
    expect(find.text('NAS · 192.168.1.20:5201'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 1));
    await tester.binding.setSurfaceSize(null);
  });
  testWidgets('desktop controls and graph fit without overflow', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    await tester.pumpWidget(const LanIperfApp());
    await tester.pumpAndSettle();
    expect(find.text('吞吐量曲线'), findsOneWidget);
    expect(find.text('开始测速'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.binding.setSurfaceSize(null);
  });
}
