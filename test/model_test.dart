import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_iperf/model.dart';

void main() {
  const device = Device('NAS', '192.168.1.10', 5201);
  test(
    'legacy download works and UDP total target is divided across streams',
    () {
      const c = TestConfig(
        device: device,
        direction: Direction.download,
        protocol: Protocol.udp,
        streams: 4,
        udpMbps: 50,
      );
      expect(
        c.arguments(streaming: true),
        containsAll(['-R', '-u', '12500000', '--json-stream']),
      );
      expect(c.arguments().contains('--json-stream'), isFalse);
      expect(c.arguments(), contains('-J'));
    },
  );
  test('reject invalid addresses and parameter boundaries', () {
    for (final host in ['', '-x', 'a b', 'http://192.168.1.10', 'a;echo x']) {
      expect(
        () => TestConfig(device: Device('', host, 5201)).validate(),
        throwsFormatException,
      );
    }
    expect(
      () => const TestConfig(device: device, seconds: 0).validate(),
      throwsFormatException,
    );
    const TestConfig(device: device, seconds: 99999).validate();
    expect(
      () => const TestConfig(device: device, seconds: 100000).validate(),
      throwsFormatException,
    );
    expect(
      () => const TestConfig(device: device, streams: 17).validate(),
      throwsFormatException,
    );
    expect(
      () => const TestConfig(device: Device('', '::1', 65536)).validate(),
      throwsFormatException,
    );
    const TestConfig(device: Device('IPv6', 'fe80::1%wlan0', 5201)).validate();
  });
  test('streaming events provide live samples and complete result', () {
    final r = StreamResult();
    r.add('{"event":"start","data":{"version":"iperf 3.17"}}');
    final s = r.add(
      '{"event":"interval","data":{"sum":{"end":1,"bits_per_second":125000000}}}',
    );
    expect(s!.mbps, 125);
    expect(s.seconds, 1);
    r.add(
      '{"event":"end","data":{"sum_received":{"bits_per_second":120000000}}}',
    );
    final result = TestResult(
      const TestConfig(device: device, direction: Direction.upload),
      r.raw,
    );
    expect(result.mbps, 120);
    expect(result.samples.length, 1);
    final restored = TestResult.fromJson(
      jsonDecode(result.exportJson) as Map<String, dynamic>,
    );
    expect(restored.config.device.host, device.host);
    expect(restored.mbps, 120);
  });
  test('UDP prefers receiver statistics, including loss and jitter', () {
    final result = TestResult(
      const TestConfig(
        device: device,
        direction: Direction.upload,
        protocol: Protocol.udp,
      ),
      {
        'end': {
          'sum_sent': {'bits_per_second': 100000000},
          'sum_received': {
            'bits_per_second': 80000000,
            'lost_percent': 20.0,
            'jitter_ms': 0.5,
          },
        },
      },
    );
    expect(result.mbps, 80);
    expect(result.loss, 20);
    expect(result.jitter, .5);
  });
  test('older UDP sums work; incomplete results and errors fail', () {
    final result = TestResult(
      const TestConfig(device: device, direction: Direction.upload),
      {
        'end': {
          'sum': {
            'bits_per_second': 42000000,
            'jitter_ms': .8,
            'lost_percent': 2,
          },
        },
      },
    );
    expect(result.mbps, 42);
    expect(
      () => TestResult(
        const TestConfig(device: device, direction: Direction.upload),
        {'error': 'Connection refused'},
      ),
      throwsFormatException,
    );
    expect(
      () => TestResult(
        const TestConfig(device: device, direction: Direction.upload),
        {},
      ),
      throwsFormatException,
    );
    expect(
      () => TestResult(
        const TestConfig(device: device, direction: Direction.upload),
        {'end': {}},
      ),
      throwsFormatException,
    );
    expect(
      Sample.fromInterval({
        'sum': {'omitted': true, 'end': 1, 'bits_per_second': 1},
      }),
      isNull,
    );
  });
}
