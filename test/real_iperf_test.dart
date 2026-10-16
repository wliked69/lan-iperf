// Optional reference-server check: set IPERF_TEST_EXECUTABLE to a trusted iperf3 binary.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_iperf/discovery.dart';

void main() {
  final binary = Platform.environment['IPERF_TEST_EXECUTABLE'];
  test('real iperf3 is confirmed and remains usable after discovery', () async {
    final reservation = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final port = reservation.port;
    await reservation.close();
    final server = await Process.start(binary!, [
      '-s',
      '-B',
      '127.0.0.1',
      '-p',
      '$port',
    ]);
    final stdout = server.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    final stderr = server.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    final scanner = LanScanner();
    final range = IPv4Range.parse('127.0.0.1/32');
    try {
      Future<void> confirm() async {
        for (var attempt = 0; attempt < 20; attempt++) {
          final result = await scanner.scan(range, port);
          if (result.isNotEmpty) {
            expect(result.single.host, '127.0.0.1');
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        fail('Reference iperf3 did not complete the expected handshake');
      }

      await confirm();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await confirm();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final client = await Process.start(binary, [
        '-c',
        '127.0.0.1',
        '-p',
        '$port',
        '-n',
        '16384',
        '-l',
        '16384',
        '-J',
      ]);
      final clientOutput = client.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();
      final clientErrors = client.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();
      try {
        final code = await client.exitCode.timeout(const Duration(seconds: 8));
        final output = await clientOutput;
        expect(code, 0, reason: '$output\n${await clientErrors}');
        final result = jsonDecode(output) as Map;
        expect(result['error'], isNull);
        expect(result['end']['sum_received']['bytes'], greaterThan(0));
      } finally {
        client.kill();
        await client.exitCode;
        await clientOutput;
        await clientErrors;
      }
    } finally {
      server.kill();
      await server.exitCode;
      await stdout;
      await stderr;
    }
  }, skip: binary == null || !File(binary).existsSync());
}
