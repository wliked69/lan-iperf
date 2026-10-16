import 'dart:convert';
import 'model.dart';

/// A server reports the forward direction as traffic from the remote client.
/// Normalize both directions to this device before rendering.
class ServerSession {
  bool active = false;
  String peer = '', status = '等待其他设备连接';
  int revision = 0, duration = 10;
  double? uploadMbps, downloadMbps;
  List<Sample> samples = [];
  void accept(Map<String, dynamic> event) {
    final data = event['data'];
    if (event['event'] == 'start' && data is Map) {
      final connections = data['connected'] as List? ?? [];
      peer = connections.isEmpty
          ? '其他设备'
          : '${(connections.first as Map)['remote_host'] ?? '其他设备'}';
      duration =
          ((data['test_start'] as Map?)?['duration'] as num?)?.toInt() ?? 10;
      active = true;
      samples = [];
      uploadMbps = null;
      downloadMbps = null;
      status = '$peer 已连接，正在测速';
      revision++;
    } else if (event['event'] == 'interval' && data is Map && active) {
      final raw = Map<String, dynamic>.from(data);
      final sample = Sample.fromInterval(raw);
      if (sample == null) return;
      final sender = (raw['sum'] as Map?)?['sender'] == true;
      final up = sample.downloadMbps ?? (sender ? sample.mbps : 0.0);
      final down = sample.downloadMbps != null
          ? sample.mbps
          : (sender ? 0.0 : sample.mbps);
      uploadMbps = up;
      downloadMbps = down;
      samples = [
        ...samples,
        Sample(
          sample.seconds,
          up,
          downloadMbps: down,
          uploadActive: sample.downloadMbps != null || sender,
        ),
      ];
      if (samples.length > 10000) {
        samples = samples.sublist(samples.length - 10000);
      }
    } else if (event['event'] == 'end' && active) {
      active = false;
      status = '$peer 测速结束';
    } else if (event['event'] == 'error' && active) {
      active = false;
      status = '$peer 测速中断：$data';
    }
  }

  void acceptLine(String line) {
    try {
      final event = jsonDecode(line);
      if (event is Map) accept(Map<String, dynamic>.from(event));
    } on FormatException {
      /* Non-JSON diagnostics never become fake samples. */
    }
  }
}
