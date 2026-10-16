import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_iperf/connection_info.dart';
import 'package:lan_iperf/discovery.dart';

void main() {
  test(
    'Wi-Fi channels distinguish 2.4, 5 and 6 GHz including special channels',
    () {
      for (final item in [
        (2412, 1, '2.4 GHz'),
        (2484, 14, '2.4 GHz'),
        (5180, 36, '5 GHz'),
        (5935, 2, '6 GHz'),
        (5955, 1, '6 GHz'),
        (7115, 233, '6 GHz'),
      ]) {
        final info = ConnectionDetails({'frequencyMHz': item.$1});
        expect(info.channel, item.$2);
        expect(info.band, item.$3);
      }
      expect(ConnectionDetails({'frequencyMHz': -1}).channel, isNull);
      expect(ConnectionDetails({'frequencyMHz': 2501}).channel, isNull);
      expect(ConnectionDetails({'channel': 36}).band, isNull);
    },
  );
  test(
    'invalid native readings are unknown rather than zero speed or signal',
    () {
      final info = ConnectionDetails({
        'txMbps': -1,
        'rxMbps': double.infinity,
        'rssi': -127,
      });
      expect(info.rate('txMbps'), '系统未提供');
      expect(info.rate('rxMbps'), '系统未提供');
      expect(info.signal, '系统未提供');
      expect(
        ConnectionDetails({'rssi': -58, 'signalPercent': 80}).signal,
        '-58 dBm · 80%',
      );
      expect(ConnectionDetails({'signalPercent': 0}).signal, '0%');
    },
  );
  testWidgets(
    'connection panel refreshes network changes and clears stale Wi-Fi data',
    (tester) async {
      var wifi = true;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        NetworkDiscovery.channel,
        (call) async {
          expect(call.method, 'connections');
          return wifi
              ? [
                  {
                    'name': 'wlan0',
                    'type': 'wifi',
                    'address': '192.168.1.2',
                    'standard': 'Wi-Fi 6 (802.11ax)',
                    'txMbps': 1201,
                    'rxMbps': 960.8,
                    'rssi': -55,
                    'frequencyMHz': 5180,
                  },
                ]
              : [
                  {
                    'name': 'Ethernet',
                    'type': 'ethernet',
                    'txMbps': 1000,
                    'rxMbps': 1000,
                  },
                ];
        },
      );
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: ConnectionInfoPanel())),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Wi-Fi 6 (802.11ax)'), findsOneWidget);
      expect(find.text('发送链路：1201 Mbps'), findsOneWidget);
      expect(find.text('信号强度：-55 dBm'), findsOneWidget);
      expect(find.text('信道：36 · 5 GHz · 5180 MHz'), findsOneWidget);
      wifi = false;
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.text('以太网 · Ethernet'), findsOneWidget);
      expect(find.textContaining('信道：'), findsNothing);
      expect(find.textContaining('信号强度：'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        NetworkDiscovery.channel,
        null,
      );
    },
  );
  testWidgets('restricted Wi-Fi shows unknown values and permission action', (
    tester,
  ) async {
    var requests = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      NetworkDiscovery.channel,
      (call) async {
        if (call.method == 'wifiPermission') {
          requests++;
          return null;
        }
        return [
          {
            'name': 'wlan0',
            'type': 'wifi',
            'note': '系统限制',
            'requestPermission': true,
          },
        ];
      },
    );
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: ConnectionInfoPanel())),
    );
    await tester.pumpAndSettle();
    expect(find.text('链路速率：系统未提供'), findsOneWidget);
    await tester.tap(find.text('允许读取 Wi-Fi 详情'));
    await tester.pumpAndSettle();
    expect(requests, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      NetworkDiscovery.channel,
      null,
    );
  });
}
