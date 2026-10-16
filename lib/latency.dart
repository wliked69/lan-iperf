import 'dart:async';
import 'dart:io';
import 'model.dart';
import 'latency_model.dart';

typedef TcpLatencyProbe =
    Future<double?> Function(Device device, Duration timeout);

class LatencyEngine {
  LatencyEngine({TcpLatencyProbe? probe}) : _probe = probe ?? tcpProbe;
  final TcpLatencyProbe _probe;
  Completer<void>? _cancel;
  bool get busy => _cancel != null;
  static Future<double?> tcpProbe(Device device, Duration timeout) async {
    Socket? socket;
    final watch = Stopwatch()..start();
    try {
      socket = await Socket.connect(device.host, device.port, timeout: timeout);
      watch.stop();
      return watch.elapsedMicroseconds / 1000;
    } on SocketException {
      return null;
    } finally {
      socket?.destroy();
    }
  }

  Future<List<LatencySample>> run(
    Device device,
    void Function(LatencySample) onSample, {
    int? count,
    int? maxRetainedSamples,
    bool Function()? shouldProbe,
    Duration interval = const Duration(milliseconds: 100),
    Duration timeout = const Duration(milliseconds: 800),
  }) async {
    if (busy) throw StateError('已有延迟测试正在运行');
    final cancel = Completer<void>();
    _cancel = cancel;
    final elapsed = Stopwatch()..start();
    final samples = <LatencySample>[];
    var completed = 0;
    try {
      while (!cancel.isCompleted && (count == null || completed < count)) {
        if (shouldProbe != null && !shouldProbe()) {
          await Future.any<void>([
            Future<void>.delayed(interval),
            cancel.future,
          ]);
          continue;
        }
        final tick = Stopwatch()..start();
        double? ms;
        try {
          ms = await _probe(device, timeout);
        } catch (_) {
          ms = null;
        }
        if (cancel.isCompleted) break;
        final sample = LatencySample(
          elapsed.elapsedMicroseconds / 1e6,
          ms != null && ms.isFinite && ms >= 0 ? ms : null,
        );
        samples.add(sample);
        completed++;
        if (maxRetainedSamples != null && samples.length > maxRetainedSamples) {
          samples.removeRange(0, samples.length - maxRetainedSamples);
        }
        onSample(sample);
        final delay = interval - tick.elapsed;
        if (delay > Duration.zero && (count == null || completed < count)) {
          await Future.any<void>([Future<void>.delayed(delay), cancel.future]);
        }
      }
      return samples;
    } finally {
      elapsed.stop();
      if (identical(_cancel, cancel)) _cancel = null;
    }
  }

  void cancel() {
    if (_cancel?.isCompleted == false) _cancel!.complete();
  }
}
