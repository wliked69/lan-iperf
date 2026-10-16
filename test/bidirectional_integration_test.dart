import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_iperf/model.dart';
import 'package:lan_iperf/engine.dart';
import 'package:lan_iperf/latency.dart';

void main() {
  final binary = Platform.environment['IPERF_TEST_EXECUTABLE'];
  test(
    'real bidirectional 100ms TCP, IPv4/IPv6, multiple streams and latency coexist',
    () async {
      final reservation = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final port = reservation.port;
      await reservation.close();
      final server = await Process.start(binary!, ['-s', '-p', '$port']);
      final stdout = server.stdout.transform(utf8.decoder).join();
      final stderr = server.stderr.transform(utf8.decoder).join();
      try {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        for (final host in ['127.0.0.1', '::1']) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
          const protocol = Protocol.tcp;
          final engine = IperfEngine();
          final latency = LatencyEngine();
          final live = <Sample>[];
          final config = TestConfig(
            device: Device('reference', host, port),
            seconds: 2,
            streams: 4,
            constantLoad: true,
            udpMbps: 16,
            protocol: protocol,
          );
          DateTime? lastReport;
          final latencyRun = latency.run(
            config.device,
            (_) {},
            shouldProbe: () =>
                lastReport != null &&
                DateTime.now().difference(lastReport!) <
                    const Duration(milliseconds: 200),
          );
          try {
            final result = await engine
                .run(config, binary, (s) {
                  lastReport = DateTime.now();
                  live.add(s);
                })
                .timeout(
                  const Duration(seconds: 10),
                  onTimeout: () async {
                    await engine.cancel();
                    throw TimeoutException('iperf bidirectional test');
                  },
                );
            expect(result.uploadMbps, inInclusiveRange(8, 24));
            expect(result.downloadMbps, inInclusiveRange(8, 24));
            expect(live.length, greaterThanOrEqualTo(12));
            expect(live.every((s) => s.downloadMbps != null), isTrue);
            expect(live[1].seconds - live[0].seconds, lessThan(.3));
          } finally {
            latency.cancel();
            await engine.cancel();
          }
          final probes = await latencyRun;
          expect(probes.where((s) => s.ms != null).length, greaterThan(5));
        }
      } finally {
        server.kill();
        await server.exitCode;
        await stdout;
        await stderr;
      }
    },
    skip: binary == null || !File(binary).existsSync(),
    timeout: const Timeout(Duration(seconds: 40)),
  );
}
