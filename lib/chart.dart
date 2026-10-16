import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'model.dart';
import 'latency_model.dart';

class ChartTimeRange {
  const ChartTimeRange(this.start, this.end);
  factory ChartTimeRange.forData(double latest, {double? windowSeconds}) {
    final end = math.max(1.0, latest);
    final start = windowSeconds == null
        ? 0.0
        : math.max(0.0, end - windowSeconds);
    return ChartTimeRange(start, end);
  }
  final double start, end;
  double get span => end - start;
}

class SpeedChart extends StatelessWidget {
  const SpeedChart({
    super.key,
    required this.samples,
    required this.duration,
    this.latencySamples = const [],
    this.direction = Direction.bidirectional,
    this.showLatency = true,
    this.windowSeconds,
    this.latencyOnly = false,
  });
  final List<Sample> samples;
  final List<LatencySample> latencySamples;
  final int duration;
  final Direction direction;
  final bool showLatency;
  final double? windowSeconds;
  final bool latencyOnly;
  bool get showUpload =>
      !latencyOnly &&
      direction != Direction.download &&
      (samples.isEmpty
          ? direction != Direction.downloadThenUpload
          : samples.any((s) => s.uploadActive));
  static const uploadColor = Color(0xff38dcc0);
  static const downloadColor = Color(0xff68a9ff);
  static const latencyColor = Color(0xffffb45e);
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Wrap(
        spacing: 18,
        runSpacing: 6,
        children: [
          if (showUpload)
            const Text('━ 上传 Mbps', style: TextStyle(color: uploadColor)),
          if (!latencyOnly && direction != Direction.upload)
            const Text('━ 下载 Mbps', style: TextStyle(color: downloadColor)),
          if (showLatency)
            const Text(
              '━ TCP 延迟 ms（右轴）',
              style: TextStyle(color: latencyColor),
            ),
        ],
      ),
      Semantics(
        label: latencyOnly
            ? 'TCP 连接延迟曲线，横轴已测秒数，右轴毫秒'
            : '上传和下载吞吐量以及 TCP 连接延迟曲线，横轴已测秒数，左轴 Mbps，右轴毫秒',
        child: SizedBox(
          height: 260,
          width: double.infinity,
          child: CustomPaint(
            painter: _SpeedPainter(
              samples,
              latencySamples,
              direction,
              showLatency,
              showUpload,
              windowSeconds,
              latencyOnly,
            ),
          ),
        ),
      ),
    ],
  );
}

class _SpeedPainter extends CustomPainter {
  _SpeedPainter(
    this.samples,
    this.latency,
    this.direction,
    this.showLatency,
    this.showUpload,
    this.windowSeconds,
    this.latencyOnly,
  );
  final List<Sample> samples;
  final List<LatencySample> latency;
  final Direction direction;
  final bool showLatency;
  final bool showUpload;
  final double? windowSeconds;
  final bool latencyOnly;
  void label(
    Canvas canvas,
    String text,
    Offset offset, [
    Color color = const Color(0xffa9b9d4),
  ]) {
    final p = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: color, fontSize: 11, fontFamily: 'Roboto'),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    p.paint(canvas, offset);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final area = Rect.fromLTRB(
      52,
      26,
      size.width - (showLatency ? 52 : 14),
      size.height - 32,
    );
    if (area.width <= 0) return;
    final range = ChartTimeRange.forData(
      math.max(
        samples.lastOrNull?.seconds ?? 0,
        showLatency ? latency.lastOrNull?.seconds ?? 0 : 0,
      ),
      windowSeconds: windowSeconds,
    );
    final visibleSamples = samples.where((s) => s.seconds >= range.start);
    final visibleLatency = latency.where((s) => s.seconds >= range.start);
    final maxSpeed = visibleSamples.fold<double>(
      0,
      (m, s) => math.max(m, math.max(s.mbps, s.downloadMbps ?? 0)),
    );
    final top = math.max(10.0, (maxSpeed * 1.15 / 10).ceil() * 10.0);
    final maxLatency = visibleLatency.fold<double>(
      0,
      (m, s) => math.max(m, s.ms ?? 0),
    );
    final latencyTop = math.max(1.0, (maxLatency * 1.15).ceilToDouble());
    final grid = Paint()
      ..color = const Color(0xff27344c)
      ..strokeWidth = 1;
    if (!latencyOnly) label(canvas, 'Mbps', const Offset(4, 2));
    if (showLatency) {
      label(canvas, 'ms', Offset(area.right + 8, 2), SpeedChart.latencyColor);
    }
    for (var i = 0; i <= 4; i++) {
      final y = area.bottom - area.height * i / 4;
      canvas.drawLine(Offset(area.left, y), Offset(area.right, y), grid);
      if (!latencyOnly) {
        label(canvas, (top * i / 4).toStringAsFixed(0), Offset(4, y - 7));
      }
      if (showLatency) {
        label(
          canvas,
          (latencyTop * i / 4).toStringAsFixed(1),
          Offset(area.right + 8, y - 7),
          SpeedChart.latencyColor,
        );
      }
      final x = area.left + area.width * i / 4;
      final tick =
          '${(range.start + range.span * i / 4).toStringAsFixed(range.end < 5 ? 1 : 0)}s';
      label(
        canvas,
        tick,
        Offset(
          (x - tick.length * 3).clamp(
            0,
            math.max(0, size.width - tick.length * 6),
          ),
          area.bottom + 10,
        ),
      );
    }
    void line(Iterable<(double, double?)> values, double maximum, Color color) {
      final path = Path();
      var connected = false;
      Offset? last;
      for (final value in values) {
        if (value.$1 < range.start || value.$1 > range.end) {
          connected = false;
          continue;
        }
        if (value.$2 == null) {
          connected = false;
          continue;
        }
        final point = Offset(
          area.left + (value.$1 - range.start) / range.span * area.width,
          area.bottom - value.$2! / maximum * area.height,
        );
        if (connected) {
          path.lineTo(point.dx, point.dy);
        } else {
          path.moveTo(point.dx, point.dy);
          connected = true;
        }
        last = point;
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
      if (last != null) canvas.drawCircle(last, 3, Paint()..color = color);
    }

    canvas.save();
    canvas.clipRect(area.inflate(3));
    if (!latencyOnly && direction == Direction.download) {
      line(
        samples.map((s) => (s.seconds, s.mbps)),
        top,
        SpeedChart.downloadColor,
      );
    } else if (showUpload) {
      line(
        samples.map((s) => (s.seconds, s.uploadActive ? s.mbps : null)),
        top,
        SpeedChart.uploadColor,
      );
    }
    if (!latencyOnly && direction != Direction.upload) {
      line(
        samples.map((s) => (s.seconds, s.downloadMbps)),
        top,
        SpeedChart.downloadColor,
      );
    }
    if (showLatency) {
      line(
        latency.map((s) => (s.seconds, s.ms)),
        latencyTop,
        SpeedChart.latencyColor,
      );
    }
    canvas.restore();
    if (samples.isEmpty && latency.isEmpty) {
      label(canvas, '开始测试后显示实际曲线', Offset(area.left + 8, area.center.dy));
    }
  }

  @override
  bool shouldRepaint(covariant _SpeedPainter old) => true;
}
