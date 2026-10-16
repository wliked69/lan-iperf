import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_iperf/latency.dart';
import 'package:lan_iperf/latency_model.dart';
import 'package:lan_iperf/model.dart';
import 'package:lan_iperf/server_session.dart';

void main() {
  test(
    'unlimited latency keeps bounded samples and totals until cancelled',
    () async {
      final engine = LatencyEngine(probe: (_, _) async => 2);
      final totals = LatencyTotals();
      final retained = await engine.run(
        const Device('local', '127.0.0.1', 5201),
        (sample) {
          totals.add(sample);
          if (totals.count == 1500) engine.cancel();
        },
        maxRetainedSamples: 1200,
        interval: Duration.zero,
      );
      expect(totals.count, 1500);
      expect(totals.average, 2);
      expect(totals.minimum, 2);
      expect(totals.maximum, 2);
      expect(totals.failures, 0);
      expect(retained.length, 1200);
      expect(engine.busy, isFalse);
    },
  );
  const device = Device('IPv6 target', '2001:db8::123', 5201);
  test('new runs use simultaneous bidirectional 100ms reports', () {
    final args = const TestConfig(device: device).arguments(streaming: true);
    expect(args, contains('--bidir'));
    expect(args[args.indexOf('-i') + 1], '0.1');
    expect(args, isNot(contains('-R')));
    expect(args[args.indexOf('-c') + 1], device.host);
  });
  test('constant target stays the same total with multiple connections', () {
    for (final streams in [1, 4, 16]) {
      for (final direction in [Direction.upload, Direction.download]) {
        final config = TestConfig(
          device: device,
          direction: direction,
          constantLoad: true,
          udpMbps: 100,
          streams: streams,
        );
        final args = config.arguments();
        expect(int.parse(args[args.indexOf('-b') + 1]) * streams, 100000000);
        expect(TestConfig.fromJson(config.toJson()).constantLoad, isTrue);
        expect(args, isNot(contains('--bidir')));
        expect(args.contains('-R'), direction == Direction.download);
      }
    }
  });
  test('both throughput directions and latency survive history round trip', () {
    final result = TestResult(
      const TestConfig(device: device),
      {
        'intervals': [
          {
            'sum': {'end': .1, 'bits_per_second': 12000000},
            'sum_bidir_reverse': {'end': .1, 'bits_per_second': 34000000},
          },
        ],
        'end': {
          'sum_received': {'bits_per_second': 11000000},
          'sum_received_bidir_reverse': {'bits_per_second': 33000000},
        },
      },
      latencySamples: const [LatencySample(.1, 2.4), LatencySample(.2, null)],
    );
    expect(result.samples.single.mbps, 12);
    expect(result.samples.single.downloadMbps, 34);
    final restored = TestResult.fromJson(result.toJson());
    expect(restored.uploadMbps, 11);
    expect(restored.downloadMbps, 33);
    expect(LatencyStats(restored.latencySamples).average, 2.4);
    expect(LatencyStats(restored.latencySamples).failures, 1);
    expect(
      () => TestResult(const TestConfig(device: device), {
        'end': {
          'sum_received': {'bits_per_second': 1000},
        },
      }),
      throwsFormatException,
    );
  });
  test(
    'server session ignores scan-only end events and swaps local directions',
    () {
      final session = ServerSession();
      session.accept({'event': 'end', 'data': {}});
      expect(session.revision, 0);
      session.accept({
        'event': 'start',
        'data': {
          'connected': [
            {'remote_host': '2001:db8::1'},
          ],
          'test_start': {'duration': 10},
        },
      });
      session.accept({
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
      expect(session.active, isTrue);
      expect(session.peer, '2001:db8::1');
      expect(session.samples.single.mbps, 20);
      expect(session.samples.single.downloadMbps, 10);
      session.accept({'event': 'end', 'data': {}});
      expect(session.active, isFalse);
      expect(session.samples, hasLength(1));
    },
  );
  test('static latency measures a real TCP socket without payload', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    var bytes = 0;
    final subscription = server.listen((socket) {
      socket.listen((data) {
        bytes += data.length;
      }, onDone: socket.destroy);
    });
    try {
      final result = await LatencyEngine().run(
        Device('local', '127.0.0.1', server.port),
        (_) {},
        count: 5,
        interval: const Duration(milliseconds: 10),
      );
      expect(result, hasLength(5));
      expect(result.every((s) => s.ms != null && s.ms! >= 0), isTrue);
      expect(bytes, 0);
    } finally {
      await subscription.cancel();
      await server.close();
    }
  });
  test(
    'latency failures are gaps and cancel stops scheduling more probes',
    () async {
      var calls = 0;
      final engine = LatencyEngine(
        probe: (_, _) async {
          calls++;
          return null;
        },
      );
      final samples = await engine.run(device, (sample) {
        engine.cancel();
      });
      expect(calls, 1);
      expect(samples.single.ms, isNull);
      expect(engine.busy, isFalse);
    },
  );
  test(
    'paused latency probing never contacts the target and remains cancellable',
    () async {
      var probes = 0;
      final engine = LatencyEngine(
        probe: (_, _) async {
          probes++;
          return 1;
        },
      );
      final future = engine.run(device, (_) {}, shouldProbe: () => false);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      engine.cancel();
      expect(await future, isEmpty);
      expect(probes, 0);
      expect(engine.busy, isFalse);
    },
  );
}
