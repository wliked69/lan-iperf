import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'discovery.dart';

class ConnectionDetails {
  ConnectionDetails(Map<dynamic, dynamic> values)
    : data = Map<String, dynamic>.from(values);
  final Map<String, dynamic> data;
  String get name => data['name'] as String? ?? '网络';
  String get type => data['type'] as String? ?? 'other';
  bool get wifi => type == 'wifi';
  String get typeLabel => switch (type) {
    'wifi' => 'Wi-Fi',
    'ethernet' => '以太网',
    'cellular' => '蜂窝网络',
    'vpn' => 'VPN',
    'bluetooth' => '蓝牙网络',
    _ => '其他网络',
  };
  double? positive(String key) {
    final value = data[key];
    return value is num && value.isFinite && value > 0
        ? value.toDouble()
        : null;
  }

  int? get frequency => positive('frequencyMHz')?.round();
  int? get channel {
    final explicit = positive('channel')?.round();
    if (explicit != null) return explicit;
    final f = frequency;
    if (f == null) return null;
    if (f == 2484) return 14;
    if (f >= 2412 && f <= 2472 && (f - 2407) % 5 == 0) return (f - 2407) ~/ 5;
    if (f >= 4910 && f <= 4980 && (f - 4000) % 5 == 0) return (f - 4000) ~/ 5;
    if (f >= 5005 && f <= 5895 && (f - 5000) % 5 == 0) return (f - 5000) ~/ 5;
    if (f == 5935) return 2;
    if (f >= 5955 && f <= 7115 && (f - 5950) % 5 == 0) return (f - 5950) ~/ 5;
    if (f >= 58320 && f <= 69120 && (f - 56160) % 2160 == 0) {
      return (f - 56160) ~/ 2160;
    }
    return null;
  }

  String? get band {
    final f = frequency;
    if (f == null) return null;
    if (f >= 2400 && f < 2500) return '2.4 GHz';
    if (f >= 4900 && f < 5925) return '5 GHz';
    if (f >= 5925 && f <= 7125) return '6 GHz';
    if (f >= 57000 && f <= 71000) return '60 GHz';
    return null;
  }

  String rate(String key) {
    final value = positive(key);
    return value == null
        ? '系统未提供'
        : '${value.toStringAsFixed(value == value.roundToDouble() ? 0 : 1)} Mbps';
  }

  String get signal {
    final parts = <String>[];
    final rssi = data['rssi'];
    if (rssi is num && rssi.isFinite && rssi < 0 && rssi > -127) {
      parts.add('${rssi.round()} dBm');
    }
    final quality = data['signalPercent'];
    if (quality is num && quality.isFinite && quality >= 0 && quality <= 100) {
      parts.add('${quality.round()}%');
    }
    return parts.isEmpty ? '系统未提供' : parts.join(' · ');
  }
}

class ConnectionInfoPanel extends StatefulWidget {
  const ConnectionInfoPanel({super.key});
  @override
  State<ConnectionInfoPanel> createState() => _ConnectionInfoPanelState();
}

class _ConnectionInfoPanelState extends State<ConnectionInfoPanel>
    with WidgetsBindingObserver {
  Timer? _timer;
  bool _reading = false;
  List<ConnectionDetails>? _rows;
  String? _error;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
    _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refresh();
      _schedule();
    } else {
      _timer?.cancel();
    }
  }

  Future<void> _refresh() async {
    if (_reading || !mounted) return;
    _reading = true;
    try {
      final values = await NetworkDiscovery.channel.invokeListMethod<dynamic>(
        'connections',
      );
      final rows = (values ?? [])
          .whereType<Map>()
          .map(ConnectionDetails.new)
          .toList();
      rows.sort(
        (a, b) => (b.data['preferred'] == true ? 1 : 0).compareTo(
          a.data['preferred'] == true ? 1 : 0,
        ),
      );
      if (mounted) {
        setState(() {
          _rows = rows;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _rows = null;
          _error = e is PlatformException
              ? e.message ?? '连接信息暂不可用'
              : '连接信息暂不可用';
        });
      }
    } finally {
      _reading = false;
    }
  }

  Future<void> _permission() async {
    try {
      await NetworkDiscovery.channel.invokeMethod<void>('wifiPermission');
      await _refresh();
    } on PlatformException catch (e) {
      if (mounted) setState(() => _error = e.message ?? '请在系统设置中允许 Wi-Fi 相关权限');
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  '本机连接信息',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                tooltip: '刷新连接信息',
                onPressed: _refresh,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          if (_error != null)
            Text(_error!, style: const TextStyle(color: Colors.orangeAccent)),
          if (_rows == null && _error == null) const Text('正在读取连接信息…'),
          if (_rows?.isEmpty == true) const Text('未检测到已连接的网络'),
          for (final row in _rows ?? <ConnectionDetails>[])
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${row.typeLabel} · ${row.name}${row.data['standard'] == null ? '' : ' · ${row.data['standard']}'}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  if (row.data['address'] != null)
                    Text(
                      '${row.data['address']}',
                      style: const TextStyle(color: Colors.white60),
                    ),
                  Wrap(
                    spacing: 22,
                    runSpacing: 6,
                    children: [
                      if (row.positive('txMbps') != null ||
                          row.positive('rxMbps') != null) ...[
                        Text('发送链路：${row.rate('txMbps')}'),
                        Text('接收链路：${row.rate('rxMbps')}'),
                      ] else
                        Text('链路速率：${row.rate('linkMbps')}'),
                      if (row.wifi) ...[
                        Text('信号强度：${row.signal}'),
                        Text(
                          '信道：${row.channel ?? '系统未提供'}${row.band == null ? '' : ' · ${row.band}'}${row.frequency == null ? '' : ' · ${row.frequency} MHz'}',
                        ),
                      ],
                    ],
                  ),
                  if (row.data['note'] is String)
                    Text(
                      row.data['note'] as String,
                      style: const TextStyle(color: Colors.orangeAccent),
                    ),
                  if (row.data['requestPermission'] == true)
                    TextButton.icon(
                      onPressed: _permission,
                      icon: const Icon(Icons.wifi),
                      label: const Text('允许读取 Wi-Fi 详情'),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 6),
          const Text(
            '每 3 秒更新。链路速率是系统报告的连接速率，不是 iperf3 实测速率；多网卡分别列出，实际测速路径由系统路由决定。',
            style: TextStyle(fontSize: 12, color: Colors.white60),
          ),
        ],
      ),
    ),
  );
}
