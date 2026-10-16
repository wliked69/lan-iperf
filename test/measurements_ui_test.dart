import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_iperf/app.dart';
import 'package:lan_iperf/latency.dart';
import 'package:lan_iperf/model.dart';
import 'package:lan_iperf/server.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'devices': jsonEncode([
        {'name': 'NAS', 'host': '192.168.1.20', 'port': 5201},
      ]),
    });
  });
  testWidgets(
    'parallel switch controls connection count, constant load exposes target',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 1000));
      await tester.pumpWidget(const LanIperfApp());
      await tester.pumpAndSettle();
      expect(find.text('先测下载，再测上传 · 每 0.1 秒更新'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, '每阶段时长（秒）'), findsOneWidget);
      final count = find.widgetWithText(TextFormField, '每方向连接数');
      expect(tester.widget<TextFormField>(count).enabled, isFalse);
      await tester.ensureVisible(find.text('多连接测速'));
      await tester.tap(find.text('多连接测速'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextFormField>(count).enabled, isTrue);
      expect(
        (await SharedPreferences.getInstance()).getBool('parallel'),
        isTrue,
      );
      await tester.ensureVisible(find.text('恒定负载测延迟'));
      await tester.tap(find.text('恒定负载测延迟'));
      await tester.pumpAndSettle();
      expect(
        find.widgetWithText(TextFormField, '每方向总目标带宽（Mbps）'),
        findsOneWidget,
      );
      expect(find.byType(SegmentedButton<Direction>), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.binding.setSurfaceSize(null);
    },
  );
  testWidgets(
    'constant load has only upload and download and remembers its own direction',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      await tester.pumpWidget(const LanIperfApp());
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('只下载'));
      await tester.tap(find.text('只下载'));
      await tester.pumpAndSettle();
      expect(
        (await SharedPreferences.getInstance()).getString('preferredDirection'),
        'download',
      );
      expect(find.text('下载测速 · 每 0.1 秒更新'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, '时长（秒）'), findsOneWidget);
      await tester.ensureVisible(find.text('只上传'));
      await tester.tap(find.text('只上传'));
      await tester.pumpAndSettle();
      expect(
        (await SharedPreferences.getInstance()).getString('preferredDirection'),
        'upload',
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.pumpWidget(const LanIperfApp());
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SegmentedButton<Direction>>(
              find.byType(SegmentedButton<Direction>),
            )
            .selected,
        {Direction.upload},
      );
      await tester.ensureVisible(find.text('恒定负载测延迟'));
      await tester.tap(find.text('恒定负载测延迟'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SegmentedButton<Direction>>(
              find.byType(SegmentedButton<Direction>),
            )
            .onSelectionChanged,
        isNotNull,
      );
      expect(find.text('恒定负载：只下载 · 每 0.1 秒更新'), findsOneWidget);
      expect(find.text('先下载后上传'), findsNothing);
      final control = tester.widget<SegmentedButton<Direction>>(
        find.byType(SegmentedButton<Direction>),
      );
      expect(control.segments.map((s) => s.value), [
        Direction.download,
        Direction.upload,
      ]);
      await tester.ensureVisible(find.text('只上传'));
      await tester.tap(find.text('只上传'));
      await tester.pumpAndSettle();
      expect(find.text('恒定负载：只上传 · 每 0.1 秒更新'), findsOneWidget);
      expect(
        (await SharedPreferences.getInstance()).getString('loadDirection'),
        'upload',
      );
      await tester.ensureVisible(find.text('恒定负载测延迟'));
      await tester.tap(find.text('恒定负载测延迟'));
      await tester.pumpAndSettle();
      expect(find.text('上传测速 · 每 0.1 秒更新'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.pumpWidget(const LanIperfApp());
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('恒定负载测延迟'));
      await tester.tap(find.text('恒定负载测延迟'));
      await tester.pumpAndSettle();
      expect(find.text('恒定负载：只上传 · 每 0.1 秒更新'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.binding.setSurfaceSize(null);
    },
  );
  testWidgets(
    'static latency continues beyond 30 probes until manually stopped',
    (tester) async {
      var probes = 0;
      await tester.binding.setSurfaceSize(const Size(1280, 1000));
      await tester.pumpWidget(
        LanIperfApp(
          latencyEngineFactory: () => LatencyEngine(
            probe: (_, _) async {
              probes++;
              return 2.5;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('静态延迟测试'));
      await tester.tap(find.text('静态延迟测试'));
      for (var i = 0; i < 35; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(probes, greaterThan(30));
      expect(find.text('静态 TCP 延迟测试 · 持续运行，点击停止结束'), findsOneWidget);
      expect(find.text('━ 上传 Mbps'), findsNothing);
      expect(find.text('━ 下载 Mbps'), findsNothing);
      await tester.ensureVisible(find.byTooltip('取消测速'));
      await tester.tap(find.byTooltip('取消测速'));
      await tester.pumpAndSettle();
      final stoppedAt = probes;
      await tester.pump(const Duration(seconds: 2));
      expect(probes, stoppedAt);
      expect(find.text('静态延迟测试已停止'), findsOneWidget);
      expect(find.text('2.50'), findsOneWidget);
      expect(find.text('0 / $stoppedAt'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.binding.setSurfaceSize(null);
    },
  );
  testWidgets(
    'incoming server event displays peer notice and local-direction curves',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      await tester.pumpWidget(const LanIperfApp());
      await tester.pumpAndSettle();
      Future<void> event(Map<String, dynamic> data) async {
        // ignore: deprecated_member_use
        await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          IperfServerController.channel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('event', jsonEncode(data)),
          ),
          (_) {},
        );
        await tester.pumpAndSettle();
      }

      await event({
        'event': 'start',
        'data': {
          'connected': [
            {'remote_host': '192.168.1.8'},
          ],
          'test_start': {'duration': 10},
        },
      });
      await event({
        'event': 'interval',
        'data': {
          'sum': {'end': .1, 'bits_per_second': 10000000, 'sender': false},
          'sum_bidir_reverse': {
            'end': .1,
            'bits_per_second': 20000000,
            'sender': true,
          },
        },
      });
      expect(find.text('本机服务端测速'), findsOneWidget);
      expect(find.textContaining('192.168.1.8 已连接'), findsWidgets);
      expect(find.text('20.0'), findsOneWidget);
      expect(find.text('10.0'), findsOneWidget);
      await event({'event': 'end', 'data': {}});
      expect(find.text('192.168.1.8 测速结束'), findsOneWidget);
      expect(find.text('20.0'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.binding.setSurfaceSize(null);
    },
  );
}
