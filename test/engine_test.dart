import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_iperf/engine.dart';
import 'package:lan_iperf/model.dart';

void main() {
  final compiler = File(
    r'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe',
  );
  final supported = Platform.isWindows && compiler.existsSync();
  late Directory temp;
  late String binary;
  setUpAll(() async {
    if (!supported) return;
    temp = await Directory.systemTemp.createTemp('lan-iperf-test-');
    binary = '${temp.path}${Platform.pathSeparator}fixture.exe';
    final c = await Process.run(compiler.path, [
      '/nologo',
      '/out:$binary',
      File('test/fixtures/fake_iperf.cs').absolute.path.replaceAll('/', r'\'),
    ]);
    expect(c.exitCode, 0, reason: '${c.stdout}\n${c.stderr}');
  });
  tearDownAll(() async {
    if (supported) await temp.delete(recursive: true);
  });
  test('Windows sends a live sample before process completion', () async {
    final engine = IperfEngine();
    final sample = Completer<Sample>();
    var completed = false;
    final result = engine.run(
      const TestConfig(device: Device('fixture', '127.0.0.1', 5201)),
      binary,
      (s) {
        if (!sample.isCompleted) sample.complete(s);
      },
    );
    result.then((_) {
      completed = true;
    });
    expect((await sample.future).mbps, 125);
    expect(completed, false);
    expect((await result).mbps, 120);
    expect(engine.busy, false);
  }, skip: !supported);
  test(
    'cancellation while process is starting terminates it and unlocks engine',
    () async {
      final engine = IperfEngine();
      final result = engine.run(
        const TestConfig(device: Device('fixture', 'hang.local', 5201)),
        binary,
        (_) {},
      );
      final assertion = expectLater(result, throwsA(isA<FormatException>()));
      await engine.cancel();
      await assertion.timeout(const Duration(seconds: 5));
      expect(engine.busy, false);
    },
    skip: !supported,
  );
  test('nonzero exit exposes stderr and permits another run', () async {
    final engine = IperfEngine();
    await expectLater(
      engine.run(
        const TestConfig(device: Device('fixture', 'error.local', 5201)),
        binary,
        (_) {},
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('connection refused'),
        ),
      ),
    );
    expect(engine.busy, false);
  }, skip: !supported);
}
