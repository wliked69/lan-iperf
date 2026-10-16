import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_iperf/engine.dart';
import 'package:lan_iperf/model.dart';

class PhaseEngine extends IperfEngine {
  PhaseEngine(this.calls, {this.failure = false, this.finished, this.wait});
  final List<Direction> calls;
  final bool failure;
  final void Function()? finished;
  final Completer<TestResult>? wait;
  bool cancelled = false;
  @override
  Future<TestResult> run(
    TestConfig config,
    String executable,
    void Function(Sample) sample, {
    void Function(Direction)? onPhase,
  }) async {
    calls.add(config.direction);
    if (failure) throw const FormatException('下载失败');
    if (wait != null) return wait!.future;
    final speed = config.direction == Direction.download ? 80.0 : 40.0;
    sample(Sample(.1, speed));
    finished?.call();
    return TestResult(config, {
      'end': {
        'sum_received': {'bits_per_second': speed * 1000000},
      },
    });
  }

  @override
  Future<void> cancel() async {
    cancelled = true;
    if (wait != null && !wait!.isCompleted) {
      wait!.completeError(const FormatException('测速已取消'));
    }
  }
}

void main() {
  const config = TestConfig(
    device: Device('target', '127.0.0.1', 5201),
    direction: Direction.downloadThenUpload,
    seconds: 1,
  );
  test(
    'download completes before upload; both summaries and curves survive history',
    () async {
      final calls = <Direction>[];
      final phases = <Direction>[];
      final samples = <Sample>[];
      final engine = IperfEngine(childFactory: () => PhaseEngine(calls));
      final result = await engine.run(
        config,
        'fixture',
        samples.add,
        onPhase: phases.add,
      );
      expect(calls, [Direction.download, Direction.upload]);
      expect(phases, calls);
      expect(samples.first.downloadMbps, 80);
      expect(samples.first.mbps, 0);
      expect(samples.first.uploadActive, isFalse);
      expect(samples.last.uploadActive, isTrue);
      expect(samples.last.mbps, 40);
      expect(samples.last.downloadMbps, isNull);
      expect(samples.last.seconds, greaterThan(samples.first.seconds));
      final restored = TestResult.fromJson(result.toJson());
      expect(restored.uploadMbps, 40);
      expect(restored.downloadMbps, 80);
      expect(restored.config.totalSeconds, 2);
      expect(restored.samples, hasLength(2));
      expect(restored.samples.first.uploadActive, isFalse);
      expect(result.raw['phase_order'], ['download', 'upload']);
      expect(engine.busy, isFalse);
    },
  );
  test('cancelling between phases never starts upload', () async {
    final calls = <Direction>[];
    final done = Completer<void>();
    final engine = IperfEngine(
      childFactory: () => PhaseEngine(
        calls,
        finished: () {
          if (!done.isCompleted) done.complete();
        },
      ),
    );
    final future = engine.run(config, 'fixture', (_) {});
    final assertion = expectLater(future, throwsFormatException);
    await done.future;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await engine.cancel();
    await assertion;
    expect(calls, [Direction.download]);
    expect(engine.busy, isFalse);
  });
  test(
    'cancelling an active download cancels its child and prevents upload',
    () async {
      final calls = <Direction>[];
      final wait = Completer<TestResult>();
      final child = PhaseEngine(calls, wait: wait);
      final engine = IperfEngine(childFactory: () => child);
      final future = engine.run(config, 'fixture', (_) {});
      final assertion = expectLater(future, throwsFormatException);
      await engine.cancel();
      await assertion;
      expect(child.cancelled, isTrue);
      expect(calls, [Direction.download]);
      expect(engine.busy, isFalse);
    },
  );
  test(
    'download failure prevents upload and a combined success result',
    () async {
      final calls = <Direction>[];
      final engine = IperfEngine(
        childFactory: () => PhaseEngine(calls, failure: true),
      );
      await expectLater(
        engine.run(config, 'fixture', (_) {}),
        throwsFormatException,
      );
      expect(calls, [Direction.download]);
      expect(engine.busy, isFalse);
    },
  );
}
