import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'model.dart';
import 'defaults.dart';

class _Run {
  bool cancelled = false;
  Process? process;
  IperfEngine? child;
  final cancellation = Completer<void>();
}

class IperfEngine {
  IperfEngine({IperfEngine Function()? childFactory})
    : _childFactory = childFactory;
  final IperfEngine Function()? _childFactory;
  static const channel = MethodChannel('cn.lanperf/iperf');
  _Run? _active;
  bool get busy => _active != null;

  Future<TestResult> run(
    TestConfig config,
    String executable,
    void Function(Sample) onSample, {
    void Function(Direction)? onPhase,
  }) async {
    config.validate();
    if (busy) throw StateError('已有测速正在运行');
    final run = _Run();
    _active = run;
    try {
      if (config.direction == Direction.downloadThenUpload) {
        return await _sequence(config, executable, onSample, onPhase, run);
      }
      if (config.seconds > maxSessionSeconds) {
        return await _longTest(config, executable, onSample, run);
      }
      Map<String, dynamic> raw;
      if (Platform.isAndroid) {
        channel.setMethodCallHandler((call) async {
          if (call.method == 'sample' && !run.cancelled) {
            final sample = Sample.fromInterval(
              jsonDecode(call.arguments as String) as Map<String, dynamic>,
            );
            if (sample != null) onSample(sample);
          }
        });
        final json = await channel.invokeMethod<String>('start', {
          'host': config.device.host,
          'port': config.device.port,
          'seconds': config.seconds,
          'streams': config.streams,
          'udpMbps': config.udpMbps,
          'udp': config.protocol == Protocol.udp,
          'reverse': config.direction == Direction.download,
          'bidirectional': config.direction == Direction.bidirectional,
          'constantLoad': config.constantLoad,
        });
        raw = jsonDecode(json!) as Map<String, dynamic>;
      } else if (Platform.isWindows) {
        var binary = executable.trim();
        if (binary.isEmpty) {
          final bundled = File(
            '${File(Platform.resolvedExecutable).parent.path}'
            '${Platform.pathSeparator}iperf3.exe',
          );
          binary = bundled.existsSync() ? bundled.path : 'iperf3.exe';
        }
        final process = await Process.start(
          binary,
          config.arguments(streaming: true),
        );
        run.process = process;
        if (run.cancelled) process.kill();
        final result = StreamResult();
        var startupTimedOut = false;
        final startupTimer = Timer(const Duration(seconds: 8), () {
          startupTimedOut = true;
          process.kill();
        });
        final stderrFuture = process.stderr
            .transform(const Utf8Decoder(allowMalformed: true))
            .join();
        final stdoutFuture = process.stdout
            .transform(const Utf8Decoder(allowMalformed: true))
            .transform(const LineSplitter())
            .forEach((line) {
              final sample = result.add(line);
              if (sample != null && !run.cancelled) {
                startupTimer.cancel();
                onSample(sample);
              }
            });
        final timer = Timer(Duration(seconds: config.seconds + 25), () {
          process.kill();
        });
        try {
          await stdoutFuture;
          final code = await process.exitCode;
          final stderr = await stderrFuture;
          if (startupTimedOut) {
            throw FormatException(
              config.protocol == Protocol.udp
                  ? 'UDP 连接启动超时，请检查端口和防火墙。Windows Cygwin 服务端的 UDP 多连接/双向存在限制，可改用 TCP 或关闭多连接。'
                  : '测速连接启动超时，请检查目标地址、端口和防火墙',
            );
          }
          if (run.cancelled) throw const FormatException('测速已取消');
          if (code != 0) {
            throw FormatException(
              '${result.raw['error'] ?? stderr.trim()}\n'
              '请检查服务器和防火墙。Windows iperf3 需支持 --json-stream（3.17 或以上）。',
            );
          }
          raw = result.raw;
        } finally {
          timer.cancel();
          startupTimer.cancel();
          process.kill();
        }
      } else {
        throw UnsupportedError('当前仅支持 Windows 和 Android');
      }
      if (run.cancelled) throw const FormatException('测速已取消');
      return TestResult(config, raw);
    } on ProcessException catch (e) {
      throw FormatException(
        '无法启动 iperf3，请选择 iperf3.exe 或加入 PATH。\n${e.message}',
      );
    } on PlatformException catch (e) {
      throw FormatException(e.message ?? '安卓原生引擎运行失败');
    } finally {
      if (Platform.isAndroid) channel.setMethodCallHandler(null);
      _active = null;
    }
  }

  Future<TestResult> _longTest(
    TestConfig config,
    String executable,
    void Function(Sample) onSample,
    _Run run,
  ) async {
    final clock = Stopwatch()..start();
    final parts = <TestResult>[];
    final intervals = <Map<String, dynamic>>[];
    var remaining = config.seconds;
    var previousEnd = 0.0;
    while (remaining > 0) {
      if (run.cancelled) throw const FormatException('测速已取消');
      final seconds = remaining.clamp(1, maxSessionSeconds);
      final child = _childFactory?.call() ?? IperfEngine();
      run.child = child;
      double? origin;
      final result = await child.run(config.withSeconds(seconds), executable, (
        sample,
      ) {
        if (run.cancelled) return;
        origin ??= (clock.elapsedMicroseconds / 1e6 - sample.seconds).clamp(
          previousEnd,
          double.infinity,
        );
        final point = Sample(
          origin! + sample.seconds,
          sample.mbps,
          downloadMbps: sample.downloadMbps,
          uploadActive: sample.uploadActive,
        );
        intervals.add({
          'sum': {
            'end': point.seconds,
            'bits_per_second': point.mbps * 1000000,
          },
          if (point.downloadMbps != null)
            'sum_bidir_reverse': {
              'end': point.seconds,
              'bits_per_second': point.downloadMbps! * 1000000,
            },
        });
        onSample(point);
      });
      run.child = null;
      if (run.cancelled) throw const FormatException('测速已取消');
      parts.add(result);
      previousEnd = (origin ?? previousEnd) + seconds;
      remaining -= seconds;
      if (remaining > 0) {
        await Future.any<void>([
          Future<void>.delayed(const Duration(milliseconds: 350)),
          run.cancellation.future,
        ]);
      }
    }
    final end = <String, dynamic>{};
    for (final key in const [
      'sum',
      'sum_sent',
      'sum_received',
      'sum_bidir_reverse',
      'sum_sent_bidir_reverse',
      'sum_received_bidir_reverse',
    ]) {
      final summaries = parts.map((p) => p.end[key]).whereType<Map>().toList();
      if (summaries.isEmpty) continue;
      num total(String field) => summaries.fold<num>(
        0,
        (value, item) => value + ((item[field] as num?) ?? 0),
      );
      final seconds = total('seconds');
      final packets = total('packets');
      end[key] = {
        'start': 0,
        'end': seconds,
        'seconds': seconds,
        'bytes': total('bytes'),
        'bits_per_second': seconds > 0 ? total('bytes') * 8 / seconds : 0,
        for (final field in ['packets', 'lost_packets', 'retransmits'])
          if (summaries.any((s) => s.containsKey(field))) field: total(field),
        if (summaries.any((s) => s.containsKey('lost_percent')))
          'lost_percent': packets > 0
              ? total('lost_packets') * 100 / packets
              : 0,
        if (summaries.any((s) => s.containsKey('jitter_ms')))
          'jitter_ms': packets > 0
              ? summaries.fold<double>(
                      0,
                      (value, s) =>
                          value +
                          ((s['jitter_ms'] as num?) ?? 0) *
                              ((s['packets'] as num?) ?? 0),
                    ) /
                    packets
              : 0,
      };
    }
    return TestResult(config, {
      'start': parts.first.raw['start'],
      'segment_results': parts.map((p) => p.raw).toList(),
      'intervals': intervals,
      'end': end,
    });
  }

  Future<TestResult> _sequence(
    TestConfig config,
    String executable,
    void Function(Sample) onSample,
    void Function(Direction)? onPhase,
    _Run run,
  ) async {
    final clock = Stopwatch()..start();
    final intervals = <Map<String, dynamic>>[];
    Future<TestResult> phase(Direction direction) async {
      if (run.cancelled) throw const FormatException('测速已取消');
      onPhase?.call(direction);
      if (run.cancelled) throw const FormatException('测速已取消');
      final child = _childFactory?.call() ?? IperfEngine();
      run.child = child;
      double? origin;
      final result = await child.run(
        config.withDirection(direction),
        executable,
        (sample) {
          if (run.cancelled) return;
          origin ??= (clock.elapsedMicroseconds / 1e6 - sample.seconds).clamp(
            0,
            double.infinity,
          );
          final point = Sample(
            origin! + sample.seconds,
            direction == Direction.upload ? sample.mbps : 0,
            downloadMbps: direction == Direction.download ? sample.mbps : null,
            uploadActive: direction == Direction.upload,
          );
          intervals.add({
            'phase': direction.name,
            'sum': {
              'end': point.seconds,
              'bits_per_second': point.mbps * 1000000,
            },
            if (point.downloadMbps != null)
              'sum_bidir_reverse': {
                'end': point.seconds,
                'bits_per_second': point.downloadMbps! * 1000000,
              },
          });
          onSample(point);
        },
      );
      run.child = null;
      if (run.cancelled) throw const FormatException('测速已取消');
      return result;
    }

    final download = await phase(Direction.download);
    // Allow the remote listener and Android's isolated client process to reset.
    await Future.any<void>([
      Future<void>.delayed(const Duration(milliseconds: 350)),
      run.cancellation.future,
    ]);
    if (run.cancelled) throw const FormatException('测速已取消');
    final upload = await phase(Direction.upload);
    return TestResult(config, {
      'start': download.raw['start'],
      'phase_order': ['download', 'upload'],
      'phase_results': {'download': download.raw, 'upload': upload.raw},
      'intervals': intervals,
      'end': {
        ...upload.end,
        'sum_received': upload.received,
        'sum_received_bidir_reverse': download.received,
        if (download.end['sum_sent'] != null)
          'sum_sent_bidir_reverse': download.end['sum_sent'],
      },
    });
  }

  Future<void> cancel() async {
    final run = _active;
    if (run == null) return;
    run.cancelled = true;
    if (!run.cancellation.isCompleted) run.cancellation.complete();
    if (run.child != null) {
      await run.child!.cancel();
      return;
    }
    if (Platform.isAndroid) {
      await channel.invokeMethod<void>('cancel');
    } else {
      run.process?.kill();
    }
  }
}
