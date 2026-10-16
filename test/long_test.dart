import 'package:flutter_test/flutter_test.dart';
import 'package:lan_iperf/engine.dart';
import 'package:lan_iperf/model.dart';

class SegmentEngine extends IperfEngine {
  SegmentEngine(this.calls, {this.after});
  final List<TestConfig> calls;
  final void Function()? after;
  @override
  Future<TestResult> run(
    TestConfig config,
    String executable,
    void Function(Sample) onSample, {
    void Function(Direction)? onPhase,
  }) async {
    calls.add(config);
    onSample(const Sample(.1, 8, downloadMbps: 16));
    final speed = calls.length == 1 ? 8 : 24;
    after?.call();
    Map<String, dynamic> summary(int multiplier) => {
      'seconds': config.seconds,
      'bytes': speed * multiplier * 1000000 ~/ 8 * config.seconds,
      'bits_per_second': speed * multiplier * 1000000,
    };
    return TestResult(config, {
      'start': {},
      'end': {
        'sum_received': summary(1),
        'sum_received_bidir_reverse': summary(2),
      },
    });
  }
}

void main() {
  const config = TestConfig(
    device: Device('target', '127.0.0.1', 5201),
    seconds: 99999,
  );
  test(
    '99999 seconds splits safely and merges weighted results and time axis',
    () async {
      final calls = <TestConfig>[];
      final points = <Sample>[];
      final engine = IperfEngine(childFactory: () => SegmentEngine(calls));
      final result = await engine.run(config, 'fixture', points.add);
      expect(calls.map((c) => c.seconds), [86400, 13599]);
      expect(
        calls.every((c) => c.direction == Direction.bidirectional),
        isTrue,
      );
      expect(points.last.seconds, greaterThanOrEqualTo(86400));
      final expected = (8 * 86400 + 24 * 13599) / 99999;
      expect(result.uploadMbps, closeTo(expected, .000001));
      expect(result.downloadMbps, closeTo(expected * 2, .000001));
      expect(TestResult.fromJson(result.toJson()).samples.length, 2);
      expect(result.received['seconds'], 99999);
    },
  );
  test('cancellation after a long segment prevents the next segment', () async {
    final calls = <TestConfig>[];
    late IperfEngine engine;
    engine = IperfEngine(
      childFactory: () => SegmentEngine(
        calls,
        after: () {
          engine.cancel();
        },
      ),
    );
    await expectLater(
      engine.run(config, 'fixture', (_) {}),
      throwsFormatException,
    );
    expect(calls.length, 1);
    expect(engine.busy, isFalse);
  });
}
