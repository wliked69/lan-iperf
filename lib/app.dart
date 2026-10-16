import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chart.dart';
import 'discovery_dialog.dart';
import 'discovery.dart';
import 'engine.dart';
import 'server.dart';
import 'model.dart';
import 'latency.dart';
import 'latency_model.dart';
import 'defaults.dart';
import 'connection_info.dart';

class LanIperfApp extends StatelessWidget {
  const LanIperfApp({
    super.key,
    this.discoveryScannerFactory,
    this.latencyEngineFactory,
    this.serverPortOverride,
  });
  final LatencyEngine Function()? latencyEngineFactory;
  final int? serverPortOverride;
  final LanScanner Function()? discoveryScannerFactory;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'LAN 测速',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff38dcc0),
        brightness: Brightness.dark,
        surface: const Color(0xff141e30),
      ),
      scaffoldBackgroundColor: const Color(0xff0b1220),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
      cardTheme: const CardThemeData(margin: EdgeInsets.zero),
    ),
    home: HomePage(
      discoveryScannerFactory: discoveryScannerFactory,
      latencyEngineFactory: latencyEngineFactory,
      serverPortOverride: serverPortOverride,
    ),
  );
}

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    this.discoveryScannerFactory,
    this.latencyEngineFactory,
    this.serverPortOverride,
  });
  final LatencyEngine Function()? latencyEngineFactory;
  final int? serverPortOverride;
  final LanScanner Function()? discoveryScannerFactory;
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _engine = IperfEngine();
  final _server = IperfServerController();
  final _listenPort = TextEditingController(text: '$defaultIperfPort');
  final _seconds = TextEditingController(text: '10');
  final _streams = TextEditingController(text: '4');
  late final _latency = widget.latencyEngineFactory?.call() ?? LatencyEngine();
  List<LatencySample> _latencySamples = [];
  LatencyTotals? _staticStats;
  bool _latencyOnly = false, _parallel = false, _constantLoad = false;
  bool get _busy => _running || _latencyOnly;
  int _serverRevision = 0;
  bool _showServerResult = false;
  Direction? _phase;
  DateTime? _lastBandwidthSample;
  Direction _direction = Direction.downloadThenUpload;
  Direction _loadDirection = Direction.download;
  final _rate = TextEditingController(text: '100');
  final _binary = TextEditingController();
  final _form = GlobalKey<FormState>();
  final _chartKey = GlobalKey();
  List<Device> _devices = [];
  List<TestResult> _history = [];
  List<Sample> _samples = [];
  Device? _device;
  TestResult? _result;
  TestConfig? _current;
  Protocol _protocol = Protocol.tcp;
  bool _running = false, _loaded = false;
  int _elapsed = 0;
  String? _error;
  String _status = '就绪';
  Timer? _timer;
  SharedPreferences? _prefs;

  @override
  void initState() {
    super.initState();
    if (widget.serverPortOverride != null) {
      _listenPort.text = '${widget.serverPortOverride}';
    }
    _server.addListener(_serverChanged);
    _load();
  }

  void _serverChanged() {
    if (!mounted) return;
    setState(() {});
    if (_server.session.revision != _serverRevision) {
      _serverRevision = _server.session.revision;
      setState(() {
        _showServerResult = !_busy;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            _showServerResult &&
            MediaQuery.sizeOf(context).width < 960 &&
            _chartKey.currentContext != null) {
          Scrollable.ensureVisible(
            _chartKey.currentContext!,
            duration: const Duration(milliseconds: 300),
          );
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${_server.session.peer} 已连接，开始测速'),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _startServer() async {
    final port = int.tryParse(_listenPort.text);
    if (port == null || port < 1 || port > 65535) {
      setState(() {
        _error = '服务端端口请输入 1–65535';
      });
      return;
    }
    if (widget.serverPortOverride == null) {
      await _prefs?.setInt('listenPort', port);
    }
    await _prefs?.setString('binary', _binary.text);
    await _server.start(binary: _binary.text, listenPort: port);
  }

  Future<void> _load() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      // Unify older installations once; subsequent manual port changes persist.
      if (widget.serverPortOverride == null &&
          _prefs!.getBool('unifiedDefaultPortV1') != true) {
        await _prefs!.setInt('listenPort', defaultIperfPort);
        await _prefs!.setBool('unifiedDefaultPortV1', true);
      }
      final devices = jsonDecode(_prefs!.getString('devices') ?? '[]') as List;
      final history = jsonDecode(_prefs!.getString('history') ?? '[]') as List;
      if (!mounted) return;
      setState(() {
        _devices = devices
            .map((j) => Device.fromJson(j as Map<String, dynamic>))
            .toList();
        _device =
            _devices
                .where((d) => d.key == _prefs!.getString('selected'))
                .firstOrNull ??
            _devices.firstOrNull;
        _history = history
            .map((j) => TestResult.fromJson(j as Map<String, dynamic>))
            .toList();
        _binary.text = _prefs!.getString('binary') ?? '';
        _parallel = _prefs!.getBool('parallel') ?? false;
        _direction =
            [Direction.downloadThenUpload, Direction.download, Direction.upload]
                .where((d) => d.name == _prefs!.getString('preferredDirection'))
                .firstOrNull ??
            Direction.downloadThenUpload;
        _loadDirection =
            [Direction.download, Direction.upload]
                .where((d) => d.name == _prefs!.getString('loadDirection'))
                .firstOrNull ??
            Direction.download;
        _streams.text = '${_prefs!.getInt('parallelStreams') ?? 4}';
        _listenPort.text =
            '${widget.serverPortOverride ?? _prefs!.getInt('listenPort') ?? defaultIperfPort}';
        _loaded = true;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loaded = true;
          _error = '本地记录读取失败：$e';
        });
      }
    }
    if (mounted) unawaited(_startServer());
  }

  Future<void> _save() async {
    await _prefs?.setString(
      'devices',
      jsonEncode(_devices.map((d) => d.toJson()).toList()),
    );
    await _prefs?.setString(
      'history',
      jsonEncode(_history.map((r) => r.toJson()).toList()),
    );
    await _prefs?.setString('binary', _binary.text);
    await _prefs?.setBool('parallel', _parallel);
    await _prefs?.setString('preferredDirection', _direction.name);
    await _prefs?.setString('loadDirection', _loadDirection.name);
    final streams = int.tryParse(_streams.text);
    if (streams != null && streams >= 1 && streams <= 16) {
      await _prefs?.setInt('parallelStreams', streams);
    }
    if (_device != null) await _prefs?.setString('selected', _device!.key);
  }

  Future<void> _persist() async {
    try {
      await _save();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '测速记录保存失败：$e';
        });
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _latency.cancel();
    _server.removeListener(_serverChanged);
    _server.dispose();
    _listenPort.dispose();
    unawaited(_engine.cancel());
    for (final c in [_seconds, _streams, _rate, _binary]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _number(String? value, int max) {
    final n = int.tryParse(value ?? '');
    return n == null || n < 1 || n > max ? '请输入 1–$max 的整数' : null;
  }

  Future<void> _addDevice({Device? edit}) async {
    final name = TextEditingController(text: edit?.name ?? '');
    final host = TextEditingController(text: edit?.host ?? '');
    final port = TextEditingController(
      text: '${edit?.port ?? defaultIperfPort}',
    );
    final form = GlobalKey<FormState>();
    final device = await showDialog<Device>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(edit == null ? '添加局域网设备' : '编辑设备'),
        content: SizedBox(
          width: 420,
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: name,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: '设备名称',
                    hintText: '例如：书房电脑 / NAS',
                  ),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: host,
                  decoration: const InputDecoration(
                    labelText: 'IP 地址或主机名',
                    hintText: '192.168.1.10 / nas.local',
                  ),
                  validator: (s) {
                    try {
                      TestConfig(
                        device: Device('', s?.trim() ?? '', defaultIperfPort),
                      ).validate();
                      return null;
                    } on FormatException catch (e) {
                      return e.message;
                    }
                  },
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: port,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'iperf3 服务端口'),
                  validator: (s) => _number(s, 65535),
                ),
                const SizedBox(height: 16),
                const Text('目标设备需运行 iperf3 -s，并允许此端口的 TCP/UDP 访问。'),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (form.currentState!.validate()) {
                Navigator.pop(
                  context,
                  Device(
                    name.text.trim().isEmpty
                        ? host.text.trim()
                        : name.text.trim(),
                    host.text.trim(),
                    int.parse(port.text),
                  ),
                );
              }
            },
            child: const Text('保存并选择'),
          ),
        ],
      ),
    );
    // Dispose after the dialog's closing animation has detached its fields.
    Future<void>.delayed(const Duration(seconds: 1), () {
      name.dispose();
      host.dispose();
      port.dispose();
    });
    if (device == null || !mounted) return;
    setState(() {
      _devices.removeWhere((d) => d.key == device.key || d.key == edit?.key);
      _devices.add(device);
      _device = device;
    });
    await _persist();
  }

  Future<void> _discover() async {
    final device = await showDialog<Device>(
      context: context,
      builder: (context) =>
          DiscoveryDialog(scanner: widget.discoveryScannerFactory?.call()),
    );
    if (!mounted || device == null) return;
    setState(() {
      final existing = _devices.where((d) => d.key == device.key).firstOrNull;
      if (existing == null) _devices.add(device);
      _device = existing ?? device;
    });
    await _persist();
  }

  Future<void> _start() async {
    if (!_form.currentState!.validate() || _device == null || _busy) return;
    final config = TestConfig(
      device: _device!,
      protocol: _protocol,
      direction: _constantLoad ? _loadDirection : _direction,
      constantLoad: _constantLoad,
      seconds: int.parse(_seconds.text),
      streams: _parallel ? int.parse(_streams.text) : 1,
      udpMbps: int.parse(_rate.text),
    );
    setState(() {
      _showServerResult = false;
      _running = true;
      _lastBandwidthSample = null;
      _phase = config.direction == Direction.downloadThenUpload
          ? Direction.download
          : config.direction;
      _samples = [];
      _latencySamples = [];
      _staticStats = null;
      _result = null;
      _error = null;
      _elapsed = 0;
      _current = config;
      _status = '正在连接 ${config.device.name}';
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          MediaQuery.sizeOf(context).width < 960 &&
          _chartKey.currentContext != null) {
        Scrollable.ensureVisible(
          _chartKey.currentContext!,
          duration: const Duration(milliseconds: 350),
        );
      }
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {
          _elapsed++;
        });
      }
    });
    final latencyRun = _latency.run(
      config.device,
      (sample) {
        if (mounted) {
          setState(() {
            _latencySamples = [..._latencySamples, sample];
          });
        }
      },
      shouldProbe: () =>
          _lastBandwidthSample != null &&
          DateTime.now().difference(_lastBandwidthSample!) <
              const Duration(milliseconds: 200),
    );
    try {
      final measured = await _engine.run(
        config,
        _binary.text,
        (s) {
          if (mounted) {
            setState(() {
              _lastBandwidthSample = DateTime.now();
              _samples = [..._samples, s];
              _status = _constantLoad
                  ? '恒定负载测延迟 · 0.1 秒更新'
                  : config.direction == Direction.downloadThenUpload
                  ? _phase == Direction.download
                        ? '正在测下载 · 完成后自动测上传 · 0.1 秒更新'
                        : '正在测上传 · 0.1 秒更新'
                  : '正在测${config.direction.label} · 0.1 秒更新';
            });
          }
        },
        onPhase: (phase) {
          if (mounted) {
            setState(() {
              _phase = phase;
              _lastBandwidthSample = null;
              _status = phase == Direction.download ? '正在测下载' : '下载已完成，正在测上传';
            });
          }
        },
      );
      _latency.cancel();
      final latency = await latencyRun;
      final result = TestResult(
        config,
        measured.raw,
        at: measured.at,
        latencySamples: latency,
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _samples = result.samples;
        _status = '测速完成';
        _history.insert(0, result);
        if (_history.length > 30) _history = _history.take(30).toList();
      });
      await _persist();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e is FormatException ? e.message : e.toString();
          _status = _error!.contains('取消') ? '已取消' : '测速失败';
        });
      }
    } finally {
      _latency.cancel();
      await latencyRun;
      _timer?.cancel();
      if (mounted) {
        setState(() {
          _running = false;
        });
      }
    }
  }

  Future<void> _staticLatency() async {
    if (_device == null || _busy) return;
    setState(() {
      _showServerResult = false;
      _latencyOnly = true;
      _staticStats = LatencyTotals();
      _samples = [];
      _latencySamples = [];
      _result = null;
      _current = TestConfig(device: _device!);
      _elapsed = 0;
      _error = null;
      _status = '静态 TCP 延迟测试 · 持续运行，点击停止结束';
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          MediaQuery.sizeOf(context).width < 960 &&
          _chartKey.currentContext != null) {
        Scrollable.ensureVisible(
          _chartKey.currentContext!,
          duration: const Duration(milliseconds: 300),
        );
      }
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {
          _elapsed++;
        });
      }
    });
    try {
      await _latency.run(_device!, (sample) {
        if (mounted) {
          setState(() {
            _staticStats!.add(sample);
            _latencySamples = [..._latencySamples, sample];
            if (_latencySamples.length > 1200) {
              _latencySamples.removeRange(0, _latencySamples.length - 1200);
            }
          });
        }
      }, maxRetainedSamples: 1200);
      if (mounted) {
        setState(() {
          _status = '静态延迟测试已停止';
        });
      }
    } finally {
      _timer?.cancel();
      if (mounted) {
        setState(() {
          _latencyOnly = false;
        });
      }
    }
  }

  Future<void> _stop() async {
    _latency.cancel();
    setState(() {
      _status = '正在取消';
    });
    try {
      await _engine.cancel();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '取消失败：$e';
        });
      }
    }
  }

  Future<void> _pickBinary() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['exe'],
      dialogTitle: '选择 iperf3.exe',
    );
    if (!mounted || picked == null) return;
    setState(() {
      _binary.text = picked.files.single.path!;
    });
    await _persist();
  }

  Widget _panel(String title, Widget child, {Widget? action, Key? key}) => Card(
    key: key,
    child: Padding(
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              ?action,
            ],
          ),
          const SizedBox(height: 20),
          child,
        ],
      ),
    ),
  );

  Widget _settings() => _panel(
    '测速设置',
    Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.dns_outlined,
                color: _server.running
                    ? const Color(0xff38dcc0)
                    : Colors.orangeAccent,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _server.starting
                      ? '服务端启动中…'
                      : _server.running
                      ? '服务端已开启 · ${_server.port}'
                      : '服务端未开启',
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_server.session.active)
            Text(
              _server.session.status,
              style: const TextStyle(color: Color(0xff38dcc0)),
            ),
          if (_server.error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                _server.error!,
                style: const TextStyle(color: Colors.orangeAccent),
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: _listenPort,
                  enabled: !_server.starting,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '本机服务端口',
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: _server.starting ? null : _startServer,
                child: const Text('重启服务端'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            '启动软件自动开启。另一台设备搜索并选择本机即可测速。安卓请保持软件打开。',
            style: TextStyle(fontSize: 12, color: Colors.white60),
          ),
          const SizedBox(height: 20),
          DropdownButtonFormField<String>(
            initialValue: _device?.key,
            key: ValueKey(_device?.key),
            isExpanded: true,
            decoration: const InputDecoration(labelText: '选择目标设备'),
            items: _devices
                .map(
                  (d) => DropdownMenuItem(
                    value: d.key,
                    child: Text(
                      '${d.name} · ${d.host}:${d.port}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                )
                .toList(),
            onChanged: _busy
                ? null
                : (key) {
                    setState(() {
                      _device = _devices.firstWhere((d) => d.key == key);
                    });
                    _persist();
                  },
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _busy || !_loaded ? null : _discover,
            icon: const Icon(Icons.radar),
            label: const Text('搜索局域网设备'),
          ),
          Row(
            children: [
              TextButton.icon(
                onPressed: _busy ? null : () => _addDevice(),
                icon: const Icon(Icons.add),
                label: const Text('添加设备'),
              ),
              TextButton(
                onPressed: _busy || _device == null
                    ? null
                    : () => _addDevice(edit: _device),
                child: const Text('编辑'),
              ),
              IconButton(
                tooltip: '删除当前设备',
                onPressed: _busy || _device == null
                    ? null
                    : () {
                        setState(() {
                          _devices.remove(_device);
                          _device = _devices.firstOrNull;
                        });
                        _persist();
                      },
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SegmentedButton<Protocol>(
            segments: const [
              ButtonSegment(value: Protocol.tcp, label: Text('TCP')),
              ButtonSegment(value: Protocol.udp, label: Text('UDP')),
            ],
            selected: {_protocol},
            onSelectionChanged: _busy
                ? null
                : (s) => setState(() {
                    _protocol = s.first;
                  }),
          ),
          const SizedBox(height: 16),
          Text(
            _constantLoad
                ? '恒定负载：只${_loadDirection.label} · 每 0.1 秒更新'
                : _direction == Direction.downloadThenUpload
                ? '先测下载，再测上传 · 每 0.1 秒更新'
                : '${_direction.label}测速 · 每 0.1 秒更新',
          ),
          const SizedBox(height: 12),
          SegmentedButton<Direction>(
            showSelectedIcon: false,
            segments: [
              if (!_constantLoad)
                const ButtonSegment(
                  value: Direction.downloadThenUpload,
                  label: Text('先下载后上传'),
                ),
              const ButtonSegment(
                value: Direction.download,
                label: Text('只下载'),
              ),
              const ButtonSegment(value: Direction.upload, label: Text('只上传')),
            ],
            selected: {_constantLoad ? _loadDirection : _direction},
            onSelectionChanged: _busy
                ? null
                : (values) {
                    setState(() {
                      if (_constantLoad) {
                        _loadDirection = values.single;
                      } else {
                        _direction = values.single;
                      }
                    });
                    unawaited(_persist());
                  },
          ),
          if (_constantLoad)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                '仅在所选方向产生恒定负载，同时测量 TCP 延迟。',
                style: TextStyle(fontSize: 12, color: Colors.white60),
              ),
            ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('多连接测速'),
            subtitle: Text(_parallel ? '开启 · 每个方向使用多路并行连接' : '关闭 · 每个方向 1 路连接'),
            value: _parallel,
            onChanged: _busy
                ? null
                : (value) {
                    setState(() {
                      _parallel = value;
                    });
                    unawaited(_persist());
                  },
          ),
          const Text(
            'Windows 多连接使用工作线程；安卓为单线程处理多连接。',
            style: TextStyle(fontSize: 12, color: Colors.white60),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('恒定负载测延迟'),
            subtitle: const Text('按指定目标带宽同时上传、下载，观察负载下的 TCP 延迟'),
            value: _constantLoad,
            onChanged: _busy
                ? null
                : (value) => setState(() {
                    _constantLoad = value;
                  }),
          ),
          const SizedBox(height: 20),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextFormField(
                  controller: _seconds,
                  enabled: !_busy,
                  decoration: InputDecoration(
                    helperText: '1–99999 秒',
                    labelText:
                        !_constantLoad &&
                            _direction == Direction.downloadThenUpload
                        ? '每阶段时长（秒）'
                        : '时长（秒）',
                  ),
                  keyboardType: TextInputType.number,
                  validator: (s) => _number(s, maxTestSeconds),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextFormField(
                  controller: _streams,
                  enabled: !_busy && _parallel,
                  decoration: const InputDecoration(labelText: '每方向连接数'),
                  keyboardType: TextInputType.number,
                  validator: (s) => _parallel ? _number(s, 16) : null,
                ),
              ),
            ],
          ),
          if (_protocol == Protocol.udp && _parallel)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text(
                'Windows Cygwin 服务端的 UDP 双向/多连接有兼容性限制；普通顺序 UDP 请先关闭多连接。',
                style: TextStyle(color: Colors.orangeAccent, fontSize: 12),
              ),
            ),
          if (_protocol == Protocol.udp || _constantLoad) ...[
            const SizedBox(height: 16),
            TextFormField(
              controller: _rate,
              enabled: !_busy,
              decoration: const InputDecoration(labelText: '每方向总目标带宽（Mbps）'),
              keyboardType: TextInputType.number,
              validator: (s) => _number(s, 10000),
            ),
            const SizedBox(height: 8),
            Text(
              _constantLoad
                  ? '仅${_loadDirection.label}使用此目标值，多连接自动分摊；实际速率受链路能力限制。'
                  : '每个测速阶段使用此目标值，多连接自动分摊；实际速率受链路能力限制。',
            ),
          ],
          if (Platform.isWindows) ...[
            const SizedBox(height: 20),
            TextFormField(
              controller: _binary,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: 'iperf3.exe 路径（可留空）',
                hintText: '留空使用程序同目录内置引擎',
                suffixIcon: IconButton(
                  tooltip: '浏览',
                  onPressed: _busy ? null : _pickBinary,
                  icon: const Icon(Icons.folder_open),
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Text('Windows 引擎要求 iperf3 3.17+。更换路径后请重启服务端。'),
          ],
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: !_loaded || _device == null || _busy ? null : _start,
            icon: const Icon(Icons.play_arrow),
            label: const Padding(
              padding: EdgeInsets.all(12),
              child: Text('开始测速'),
            ),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: !_loaded || _device == null || _busy
                ? null
                : _staticLatency,
            icon: const Icon(Icons.network_check),
            label: const Text('静态延迟测试'),
          ),
          if (_busy) ...[
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _stop,
              icon: const Icon(Icons.stop),
              label: const Text('停止测试'),
            ),
          ],
          const SizedBox(height: 16),
          const Text(
            '上传：本机 → 目标设备\n下载：目标设备 → 本机',
            style: TextStyle(color: Color(0xffa9b9d4), height: 1.6),
          ),
        ],
      ),
    ),
  );

  Widget _metric(String label, String value) => SizedBox(
    width: 140,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Color(0xffa9b9d4))),
        const SizedBox(height: 8),
        Text(
          value,
          style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w600),
        ),
      ],
    ),
  );
  Widget _incomingResults() => _panel(
    '本机服务端测速',
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _server.session.status,
          style: const TextStyle(color: Color(0xff38dcc0)),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 24,
          runSpacing: 12,
          children: [
            _metric(
              '本机上传（Mbps）',
              _server.session.uploadMbps?.toStringAsFixed(1) ?? '—',
            ),
            _metric(
              '本机下载（Mbps）',
              _server.session.downloadMbps?.toStringAsFixed(1) ?? '—',
            ),
          ],
        ),
        const SizedBox(height: 20),
        SpeedChart(
          samples: _server.session.samples,
          duration: _server.session.duration,
          windowSeconds: _server.session.active ? 60 : null,
          showLatency: false,
        ),
        const SizedBox(height: 8),
        const Text('上传表示本机发送，下载表示本机接收。连接结束后保留曲线。'),
      ],
    ),
    key: _chartKey,
  );

  Widget _results() {
    if (_showServerResult) return _incomingResults();
    final config = _current;
    final latest = _samples.lastOrNull;
    return _panel(
      _staticStats != null ? '静态延迟曲线' : '吞吐量曲线',
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 20,
            runSpacing: 18,
            children: [
              _metric(
                _running
                    ? (config?.direction == Direction.download
                          ? '上传不测（Mbps）'
                          : _phase == Direction.download
                          ? '上传待测（Mbps）'
                          : '当前上传（Mbps）')
                    : '上传平均（Mbps）',
                (_running
                            ? (_phase == Direction.download
                                  ? null
                                  : latest?.mbps)
                            : _result?.uploadMbps)
                        ?.toStringAsFixed(1) ??
                    '—',
              ),
              _metric(
                _running
                    ? (config?.direction == Direction.upload
                          ? '下载不测（Mbps）'
                          : _phase == Direction.upload
                          ? '下载末次（Mbps）'
                          : '当前下载（Mbps）')
                    : '下载平均（Mbps）',
                (_running
                            ? (_phase == Direction.upload
                                  ? _samples
                                        .where((s) => s.downloadMbps != null)
                                        .lastOrNull
                                        ?.downloadMbps
                                  : config?.direction == Direction.download
                                  ? latest?.mbps
                                  : latest?.downloadMbps)
                            : _result?.downloadMbps)
                        ?.toStringAsFixed(1) ??
                    '—',
              ),
              _metric(
                'TCP 延迟平均（ms）',
                (_staticStats?.average ?? LatencyStats(_latencySamples).average)
                        ?.toStringAsFixed(2) ??
                    '—',
              ),
              _metric(
                '最低 / 最高（ms）',
                '${(_staticStats?.minimum ?? LatencyStats(_latencySamples).minimum)?.toStringAsFixed(2) ?? '—'} / ${(_staticStats?.maximum ?? LatencyStats(_latencySamples).maximum)?.toStringAsFixed(2) ?? '—'}',
              ),
              _metric(
                '延迟探测失败',
                '${_staticStats?.failures ?? LatencyStats(_latencySamples).failures} / ${_staticStats?.count ?? _latencySamples.length}',
              ),
              _metric('已用时间', '$_elapsed s'),
              if (_result?.jitter != null)
                _metric('上传 UDP 抖动（ms）', _result!.jitter!.toStringAsFixed(3)),
              if (_result?.loss != null)
                _metric('上传 UDP 丢包率', '${_result!.loss!.toStringAsFixed(2)}%'),
              if (_result?.retransmits != null)
                _metric('TCP 重传', '${_result!.retransmits}'),
            ],
          ),
          const SizedBox(height: 20),
          SpeedChart(
            samples: _samples,
            duration: config?.totalSeconds ?? 10,
            windowSeconds: _busy || _staticStats != null ? 60 : null,
            latencyOnly: _staticStats != null,
            latencySamples: _latencySamples,
            direction: config?.direction ?? Direction.bidirectional,
          ),
          const SizedBox(height: 6),
          const Text(
            '延迟为到目标服务端口的 TCP 连接耗时（含本机调度），不是 ICMP ping。静态测试不传输测速数据。',
            style: TextStyle(fontSize: 12, color: Colors.white60),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              if (_busy) ...[
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(child: Text(_status)),
              if (_busy)
                IconButton(
                  tooltip: '取消测速',
                  onPressed: _stop,
                  icon: const Icon(Icons.stop_circle_outlined),
                ),
              if (_result != null)
                TextButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(text: _result!.exportJson),
                    );
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('测速 JSON 已复制')),
                      );
                    }
                  },
                  icon: const Icon(Icons.copy),
                  label: const Text('复制 JSON'),
                ),
            ],
          ),
          if (_server.session.samples.isNotEmpty || _server.session.active) ...[
            const Divider(height: 32),
            const Text(
              '本机作为服务端',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              _server.session.status,
              style: const TextStyle(color: Color(0xff38dcc0)),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 24,
              runSpacing: 12,
              children: [
                _metric(
                  '本机上传（Mbps）',
                  _server.session.uploadMbps?.toStringAsFixed(1) ?? '—',
                ),
                _metric(
                  '本机下载（Mbps）',
                  _server.session.downloadMbps?.toStringAsFixed(1) ?? '—',
                ),
              ],
            ),
            const SizedBox(height: 12),
            SpeedChart(
              samples: _server.session.samples,
              duration: _server.session.duration,
              windowSeconds: _server.session.active ? 60 : null,
              showLatency: false,
            ),
          ],
          if (config != null)
            Text(
              '${config.device.name} · ${config.device.host}:${config.device.port}'
              ' · ${config.protocol.name.toUpperCase()} · ${config.direction.label} · 每方向 ${config.streams} 路${config.constantLoad ? ' · 恒定目标 ${config.udpMbps} Mbps/方向' : ''}',
              style: const TextStyle(color: Color(0xffa9b9d4)),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: SelectableText(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
      key: _chartKey,
    );
  }

  Widget _historyPanel() => _panel(
    '最近记录',
    Column(
      children: [
        if (_history.isEmpty)
          const Padding(
            padding: EdgeInsets.all(20),
            child: Text('完成测速后自动保存，最多保留 30 次。'),
          ),
        for (final result in _history)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              result.config.direction.hasBoth
                  ? Icons.swap_vert
                  : result.config.direction == Direction.upload
                  ? Icons.upload
                  : Icons.download,
            ),
            title: Text(
              '${result.config.device.name} · ${result.config.direction.hasBoth ? '↑ ${result.mbps.toStringAsFixed(1)} / ↓ ${result.downloadMbps!.toStringAsFixed(1)}' : result.mbps.toStringAsFixed(1)} Mbps',
            ),
            subtitle: Text(
              '${result.config.protocol.name.toUpperCase()} · '
              '${result.config.device.host}:${result.config.device.port}\n'
              '${result.at.toLocal().toString().split('.').first}',
            ),
            trailing: const Icon(Icons.chevron_right),
            isThreeLine: true,
            onTap: _busy
                ? null
                : () => setState(() {
                    _showServerResult = false;
                    _result = result;
                    _current = result.config;
                    _samples = result.samples;
                    _latencySamples = result.latencySamples;
                    _staticStats = null;
                    _elapsed = result.config.seconds;
                    _status = '历史记录';
                    _error = null;
                  }),
          ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Row(
        children: [
          Icon(Icons.network_check),
          SizedBox(width: 12),
          Text('LAN 测速'),
        ],
      ),
      actions: [
        IconButton(
          tooltip: '使用说明',
          icon: const Icon(Icons.help_outline),
          onPressed: () => showDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('连接局域网设备'),
              content: const SelectableText(
                '1. 将本机和目标设备接入同一局域网。\n\n'
                '2. 两台设备打开本软件，等待“服务端已开启”。默认端口为 5201。\n\n'
                '3. 放行服务端防火墙的 TCP 5201；UDP 测试还需 UDP 5201。\n\n'
                '4. 添加目标设备 IP，选择它，再开始测速。\n\n'
                '软件启动会自动开启服务端，退出会关闭；安卓请保持软件打开。NAS 等其他设备仍需运行 iperf3 -s。\n\n'
                '普通测速默认先下载后上传，也可选择只下载或只上传；顺序模式每阶段使用设定时长；恒定负载模式可选择只上传或只下载。曲线每 0.1 秒更新。延迟为 TCP 连接耗时，可单独测试或配合恒定负载测试。',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('知道了'),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
    body: LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: EdgeInsets.all(constraints.maxWidth < 700 ? 16 : 28),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1320),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '测量设备之间的真实带宽',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                const Text(
                  '选择局域网设备，实时观察链路吞吐量。',
                  style: TextStyle(color: Color(0xffa9b9d4)),
                ),
                const SizedBox(height: 26),
                const ConnectionInfoPanel(),
                const SizedBox(height: 20),
                if (constraints.maxWidth >= 960)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(width: 370, child: _settings()),
                      const SizedBox(width: 22),
                      Expanded(
                        child: Column(
                          children: [
                            _results(),
                            const SizedBox(height: 22),
                            _historyPanel(),
                          ],
                        ),
                      ),
                    ],
                  )
                else ...[
                  _settings(),
                  const SizedBox(height: 20),
                  _results(),
                  const SizedBox(height: 20),
                  _historyPanel(),
                ],
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
