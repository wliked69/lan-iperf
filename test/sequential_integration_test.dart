import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_iperf/engine.dart';
import 'package:lan_iperf/model.dart';
import 'package:lan_iperf/latency.dart';

void main() {
  final binary = Platform.environment['IPERF_TEST_EXECUTABLE'];
  test(
    'real TCP and single-connection UDP run download then upload at 100ms',
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
        await Future<void>.delayed(const Duration(milliseconds: 400));
        for (final protocol in Protocol.values) {
          final engine = IperfEngine();
          final latency = LatencyEngine();
          DateTime? lastReport;
          final latencyRun = latency.run(
            Device('reference', '127.0.0.1', port),
            (_) {},
            shouldProbe: () =>
                lastReport != null &&
                DateTime.now().difference(lastReport!) <
                    const Duration(milliseconds: 200),
          );
          final phases = <Direction>[];
          final samples = <Sample>[];
          try {
            final result = await engine
                .run(
                  TestConfig(
                    device: Device('reference', '127.0.0.1', port),
                    direction: Direction.downloadThenUpload,
                    seconds: 1,
                    protocol: protocol,
                    udpMbps: 4,
                  ),
                  binary,
                  (s) {
                    lastReport = DateTime.now();
                    samples.add(s);
                  },
                  onPhase: (phase) {
                    lastReport = null;
                    phases.add(phase);
                  },
                )
                .timeout(const Duration(seconds: 14));
            expect(phases, [Direction.download, Direction.upload]);
            expect(result.uploadMbps, greaterThan(0));
            expect(result.downloadMbps, greaterThan(0));
            final intervals = result.raw['intervals'] as List;
            final firstUpload = intervals.indexWhere(
              (i) => i['phase'] == 'upload',
            );
            expect(firstUpload, greaterThanOrEqualTo(5));
            expect(
              intervals
                  .take(firstUpload)
                  .every((i) => i['phase'] == 'download'),
              isTrue,
            );
            expect(
              intervals.skip(firstUpload).every((i) => i['phase'] == 'upload'),
              isTrue,
            );
            expect(
              samples[firstUpload].seconds,
              greaterThan(samples[firstUpload - 1].seconds),
            );
            expect(samples[1].seconds - samples[0].seconds, lessThan(.3));
          } finally {
            latency.cancel();
            await engine.cancel();
            final probes = await latencyRun;
            expect(probes.where((p) => p.ms != null).length, greaterThan(5));
          }
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
