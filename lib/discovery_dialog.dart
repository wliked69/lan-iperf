import 'package:flutter/material.dart';
import 'discovery.dart';
import 'model.dart';
import 'defaults.dart';

class DiscoveryDialog extends StatefulWidget {
  const DiscoveryDialog({super.key, this.scanner});
  final LanScanner? scanner;
  @override
  State<DiscoveryDialog> createState() => _DiscoveryDialogState();
}

class _DiscoveryDialogState extends State<DiscoveryDialog> {
  late final LanScanner _scanner;
  final _range = TextEditingController();
  final _port = TextEditingController(text: '$defaultIperfPort');
  final _form = GlobalKey<FormState>();
  List<LocalNetwork> _networks = [];
  final List<Device> _found = [];
  LocalNetwork? _network;
  bool _loading = true,
      _scanning = false,
      _cancelled = false,
      _finished = false;
  int _completed = 0, _total = 0;
  String? _error;
  @override
  void initState() {
    super.initState();
    _scanner = widget.scanner ?? LanScanner();
    _load();
  }

  Future<void> _load() async {
    try {
      final networks = await NetworkDiscovery.networks();
      if (!mounted) return;
      setState(() {
        _networks = networks;
        _network = networks.firstOrNull;
        _range.text = _network?.suggestedRange ?? '';
        _loading = false;
        if (_networks.isEmpty) _error = '未识别到局域网网卡，请连接 Wi-Fi/网线，或手动输入网段。';
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '读取本机网络失败，请手动输入网段。';
        });
      }
    }
  }

  Future<void> _scan() async {
    if (!_form.currentState!.validate() || _scanning) return;
    final range = IPv4Range.parse(_range.text);
    setState(() {
      _scanning = true;
      _cancelled = false;
      _finished = false;
      _found.clear();
      _error = null;
      _completed = 0;
      _total = 0;
    });
    try {
      await _scanner.scan(
        range,
        int.parse(_port.text),
        exclude: _networks.map((n) => n.address).toSet(),
        onProgress: (done, total) {
          if (mounted) {
            setState(() {
              _completed = done;
              _total = total;
            });
          }
        },
        onFound: (device) {
          if (mounted) {
            setState(() {
              _found.add(device);
            });
          }
        },
      );
      if (mounted) {
        setState(() {
          _finished = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _scanning = false;
        });
      }
    }
  }

  void _stop() {
    _scanner.cancel();
    setState(() {
      _cancelled = true;
    });
  }

  void _choose(Device device) {
    _scanner.cancel();
    Navigator.pop(context, device);
  }

  @override
  void dispose() {
    _scanner.cancel();
    _range.dispose();
    _port.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('搜索局域网设备'),
    content: SizedBox(
      width: 520,
      height: 500,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('识别 iperf3 服务端，只显示通过协议握手确认的 IP。'),
          const SizedBox(height: 16),
          if (_loading) const LinearProgressIndicator(),
          if (_networks.isNotEmpty) ...[
            DropdownButtonFormField<String>(
              initialValue: _network?.address,
              decoration: const InputDecoration(labelText: '本机网络'),
              isExpanded: true,
              items: _networks
                  .map(
                    (n) => DropdownMenuItem(
                      value: n.address,
                      child: Text(
                        '${n.name} · ${n.address}/${n.prefix}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: _scanning
                  ? null
                  : (address) => setState(() {
                      _network = _networks.firstWhere(
                        (n) => n.address == address,
                      );
                      _range.text = _network!.suggestedRange;
                    }),
            ),
            const SizedBox(height: 12),
          ],
          Form(
            key: _form,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 3,
                  child: TextFormField(
                    controller: _range,
                    enabled: !_scanning && !_loading,
                    decoration: const InputDecoration(
                      labelText: '扫描网段',
                      hintText: '192.168.1.0/24',
                    ),
                    validator: (value) {
                      try {
                        IPv4Range.parse(value ?? '');
                        return null;
                      } on FormatException catch (e) {
                        return e.message;
                      }
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: TextFormField(
                    controller: _port,
                    enabled: !_scanning,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '服务端口'),
                    validator: (value) {
                      final port = int.tryParse(value ?? '');
                      return port == null || port < 1 || port > 65535
                          ? '1–65535'
                          : null;
                    },
                  ),
                ),
              ],
            ),
          ),
          if (_network?.narrowed ?? false)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '大网段默认扫描本机附近的 /24；可修改范围，每次最多 4094 个地址。',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: Text(
                  _scanning
                      ? '${_cancelled ? '正在停止' : '正在搜索'} · $_completed/$_total · 发现 ${_found.length} 台'
                      : _finished
                      ? '${_cancelled ? '已停止' : '扫描完成'} · 发现 ${_found.length} 台'
                      : '点击开始搜索',
                ),
              ),
              if (_scanning)
                TextButton(
                  onPressed: _cancelled ? null : _stop,
                  child: const Text('停止'),
                )
              else
                FilledButton(
                  onPressed: _loading ? null : _scan,
                  child: const Text('开始搜索'),
                ),
            ],
          ),
          if (_scanning) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: _total == 0 ? null : _completed / _total,
            ),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 8),
          Expanded(
            child: _found.isEmpty
                ? Center(
                    child: Text(
                      _finished
                          ? '没有发现可确认的 iperf3 服务端。\n请确认网段、端口，并在目标设备运行 iperf3 -s。'
                          : '发现的设备会显示在这里',
                      textAlign: TextAlign.center,
                    ),
                  )
                : ListView.builder(
                    itemCount: _found.length,
                    itemBuilder: (context, index) {
                      final d = _found[index];
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.computer),
                        title: Text('${d.host}:${d.port}'),
                        subtitle: const Text('已确认 iperf3 · 点击选择'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _choose(d),
                      );
                    },
                  ),
          ),
          const Text(
            '普通开放端口会被过滤；握手期间不创建测速数据流。',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () {
          _scanner.cancel();
          Navigator.pop(context);
        },
        child: const Text('关闭'),
      ),
    ],
  );
}
