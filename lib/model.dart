import 'dart:convert';
import 'latency_model.dart';
import 'defaults.dart';

enum Protocol { tcp, udp }

enum Direction {
  upload,
  download,
  bidirectional,
  downloadThenUpload;

  bool get hasBoth => this == bidirectional || this == downloadThenUpload;

  String get label => switch (this) {
    upload => '上传',
    download => '下载',
    bidirectional => '双向同时',
    downloadThenUpload => '先下载后上传',
  };
}

class Device {
  const Device(this.name, this.host, this.port);
  final String name;
  final String host;
  final int port;
  String get key => '$host:$port';
  Map<String, dynamic> toJson() => {'name': name, 'host': host, 'port': port};
  factory Device.fromJson(Map<String, dynamic> j) =>
      Device(j['name'] as String, j['host'] as String, j['port'] as int);
}

class TestConfig {
  const TestConfig({
    required this.device,
    this.protocol = Protocol.tcp,
    this.direction = Direction.bidirectional,
    this.constantLoad = false,
    this.seconds = 10,
    this.streams = 1,
    this.udpMbps = 100,
  });
  final Device device;
  final Protocol protocol;
  final Direction direction;
  final bool constantLoad;
  final int seconds, streams, udpMbps;
  TestConfig withSeconds(int value) => TestConfig(
    device: device,
    protocol: protocol,
    direction: direction,
    constantLoad: constantLoad,
    seconds: value,
    streams: streams,
    udpMbps: udpMbps,
  );
  int get totalSeconds =>
      seconds * (direction == Direction.downloadThenUpload ? 2 : 1);
  TestConfig withDirection(Direction value) => TestConfig(
    device: device,
    protocol: protocol,
    direction: value,
    constantLoad: constantLoad,
    seconds: seconds,
    streams: streams,
    udpMbps: udpMbps,
  );

  void validate() {
    if (device.host.isEmpty ||
        device.host.startsWith('-') ||
        !RegExp(r'^[a-zA-Z0-9._:%-]+$').hasMatch(device.host)) {
      throw const FormatException('请输入设备的 IP 地址或主机名，不要包含 URL、空格或方括号');
    }
    if (device.port < 1 || device.port > 65535) {
      throw const FormatException('端口范围为 1–65535');
    }
    if (seconds < 1 || seconds > maxTestSeconds) {
      throw const FormatException('时长范围为 1–99999 秒');
    }
    if (streams < 1 || streams > 16) {
      throw const FormatException('并行连接数范围为 1–16');
    }
    if (udpMbps < 1 || udpMbps > 10000) {
      throw const FormatException('UDP 速率范围为 1–10000 Mbps');
    }
  }

  List<String> arguments({bool streaming = false}) {
    validate();
    if (direction == Direction.downloadThenUpload) {
      throw const FormatException('顺序测速需要由客户端分别运行下载和上传阶段');
    }
    return [
      '-c',
      device.host,
      '-p',
      '${device.port}',
      '-t',
      '$seconds',
      '-P',
      '$streams',
      '-i',
      '0.1',
      '--connect-timeout',
      '5000',
      if (streaming) ...['--json-stream', '--forceflush'] else '-J',
      if (direction == Direction.download) '-R',
      if (direction == Direction.bidirectional) '--bidir',
      if (protocol == Protocol.udp) ...['-u', '-l', '1200'],
      if (protocol == Protocol.udp || constantLoad) ...[
        '-b',
        '${udpMbps * 1000000 ~/ streams}',
      ],
    ];
  }

  Map<String, dynamic> toJson() => {
    'device': device.toJson(),
    'protocol': protocol.name,
    'direction': direction.name,
    'constantLoad': constantLoad,
    'seconds': seconds,
    'streams': streams,
    'udpMbps': udpMbps,
  };
  factory TestConfig.fromJson(Map<String, dynamic> j) => TestConfig(
    device: Device.fromJson(j['device'] as Map<String, dynamic>),
    protocol: Protocol.values.byName(j['protocol'] as String),
    direction: Direction.values.byName(j['direction'] as String? ?? 'upload'),
    constantLoad: j['constantLoad'] as bool? ?? false,
    seconds: j['seconds'] as int,
    streams: j['streams'] as int,
    udpMbps: j['udpMbps'] as int,
  );
}

class Sample {
  const Sample(
    this.seconds,
    this.mbps, {
    this.downloadMbps,
    this.uploadActive = true,
  });
  final bool uploadActive;
  final double? downloadMbps;
  final double seconds, mbps;
  static Sample? fromInterval(Map<String, dynamic> interval) {
    final sum = interval['sum'] as Map<String, dynamic>?;
    if (sum == null || sum['omitted'] == true) return null;
    final bps = sum['bits_per_second'] as num?;
    final end = sum['end'] as num?;
    if (bps == null || end == null || !bps.isFinite || !end.isFinite) {
      return null;
    }
    final reverse = interval['sum_bidir_reverse'] as Map<String, dynamic>?;
    final down = reverse?['bits_per_second'] as num?;
    if (down != null && (!down.isFinite || down < 0)) return null;
    return Sample(
      end.toDouble(),
      bps.toDouble() / 1000000,
      downloadMbps: down == null ? null : down.toDouble() / 1000000,
      uploadActive: interval['phase'] != 'download',
    );
  }
}

class TestResult {
  TestResult(
    this.config,
    this.raw, {
    DateTime? at,
    this.latencySamples = const [],
  }) : at = at ?? DateTime.now() {
    if (raw['error'] != null) throw FormatException('${raw['error']}');
    if (raw['end'] is! Map) throw const FormatException('未收到完整的 iperf3 结果');
    final speed = received['bits_per_second'];
    if (speed is! num || !speed.isFinite || speed < 0) {
      throw const FormatException('iperf3 结果缺少有效的吞吐量统计');
    }
    if (config.direction.hasBoth && downloadMbps == null) {
      throw const FormatException('缺少下载统计，请确认服务端支持 iperf3 双向测试');
    }
  }
  final TestConfig config;
  final Map<String, dynamic> raw;
  final DateTime at;
  final List<LatencySample> latencySamples;
  Map<String, dynamic> get reverseReceived => Map<String, dynamic>.from(
    end['sum_received_bidir_reverse'] ?? end['sum_bidir_reverse'] ?? {},
  );
  double? get uploadMbps =>
      config.direction == Direction.download ? null : mbps;
  double? get downloadMbps {
    if (config.direction == Direction.download) return mbps;
    final value = reverseReceived['bits_per_second'];
    return value is num && value.isFinite && value >= 0
        ? value / 1000000
        : null;
  }

  double? get downloadJitter =>
      (reverseReceived['jitter_ms'] as num?)?.toDouble();
  double? get downloadLoss =>
      (reverseReceived['lost_percent'] as num?)?.toDouble();
  Map<String, dynamic> get end => Map<String, dynamic>.from(raw['end'] as Map);
  // Prefer receiver-side throughput: UDP sender rate does not account for loss.
  Map<String, dynamic> get received {
    final summary = end['sum_received'] ?? end['sum'] ?? end['sum_sent'] ?? {};
    if (summary is! Map) throw const FormatException('iperf3 吞吐量统计格式无效');
    return Map<String, dynamic>.from(summary);
  }

  double get mbps => ((received['bits_per_second'] as num?) ?? 0) / 1000000;
  double? get jitter => (received['jitter_ms'] as num?)?.toDouble();
  double? get loss => (received['lost_percent'] as num?)?.toDouble();
  int? get retransmits => (end['sum_sent']?['retransmits'] as num?)?.toInt();
  List<Sample> get samples => (raw['intervals'] as List? ?? [])
      .map((i) => Sample.fromInterval(i as Map<String, dynamic>))
      .whereType<Sample>()
      .toList();
  Map<String, dynamic> toJson() => {
    'at': at.toIso8601String(),
    'config': config.toJson(),
    'raw': raw,
    'latencySamples': latencySamples.map((s) => s.toJson()).toList(),
  };
  factory TestResult.fromJson(Map<String, dynamic> j) => TestResult(
    TestConfig.fromJson(j['config'] as Map<String, dynamic>),
    j['raw'] as Map<String, dynamic>,
    at: DateTime.parse(j['at'] as String),
    latencySamples: (j['latencySamples'] as List? ?? [])
        .map((s) => LatencySample.fromJson(Map<String, dynamic>.from(s as Map)))
        .toList(),
  );
  String get exportJson => const JsonEncoder.withIndent('  ').convert(toJson());
}

/// Converts iperf3 3.17+ newline-delimited JSON events into a standard result.
class StreamResult {
  final Map<String, dynamic> raw = {'intervals': <Map<String, dynamic>>[]};
  Sample? add(String line) {
    if (line.trim().isEmpty) return null;
    final j = jsonDecode(line) as Map<String, dynamic>;
    final data = j['data'];
    switch (j['event']) {
      case 'start':
        raw['start'] = data;
      case 'interval':
        (raw['intervals'] as List).add(data);
        return Sample.fromInterval(data as Map<String, dynamic>);
      case 'end':
        raw['end'] = data;
      case 'error':
        raw['error'] = data;
    }
    return null;
  }
}
