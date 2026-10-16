import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'discovery.dart';
import 'server_session.dart';
import 'defaults.dart';

/// Native hosts own the server lifetime, including when the application exits.
class IperfServerController extends ChangeNotifier {
  IperfServerController({
    IperfProbe? readinessProbe,
    Future<void> Function(int)? reservePort,
  }) : _probe = readinessProbe ?? LanScanner.probeIperf3,
       _reservePort = reservePort ?? _reserve;
  final Future<void> Function(int) _reservePort;
  static Future<void> _reserve(int port) async {
    final socket = await ServerSocket.bind(InternetAddress.anyIPv4, port);
    await socket.close();
  }

  static bool isAddressInUse(SocketException error) =>
      const {48, 98, 10048}.contains(error.osError?.errorCode) ||
      (error.osError?.errorCode == -1 &&
          error.toString().contains('shared flag'));
  static String describeFailure(Object error, int port) {
    if (error is SocketException) {
      final code = error.osError?.errorCode;
      final detail =
          '${error.osError?.message ?? error.message}${code == null ? '' : '（错误码 $code）'}';
      if (isAddressInUse(error)) {
        return '端口 $port 仍被占用，请停止其他 iperf3 服务或更换端口。$detail';
      }
      if (code == 10013) return '端口 $port 无法监听，可能被其他程序独占或受系统限制。$detail';
      if (const {1, 13}.contains(code)) {
        return '系统拒绝监听端口 $port，请检查应用网络权限。$detail';
      }
      return '无法监听端口 $port：$detail';
    }
    if (error is PlatformException) {
      return '启动失败：${error.message ?? error.code}';
    }
    if (error is StateError) return '启动失败：${error.message}';
    if (error is TimeoutException) return '等待服务端启动或退出超时，请重试';
    return '启动失败：$error';
  }

  final _closed = Completer<void>();
  Future<void> _nativeCommand(
    String method, {
    Map<String, Object>? arguments,
    required Duration timeout,
  }) => Future.any<void>([
    channel.invokeMethod<void>(method, arguments),
    _closed.future,
  ]).timeout(timeout);
  final IperfProbe _probe;
  static const channel = MethodChannel('cn.lanperf/server');
  bool starting = false, running = false, _disposed = false;
  int port = defaultIperfPort;
  String? error;
  Timer? _monitor;
  bool _checking = false, _polling = false;
  final session = ServerSession();
  Timer? _events;
  String _pendingOutput = '';
  void _event(String line) {
    session.acceptLine(line);
    if (!_disposed) notifyListeners();
  }

  Future<void> _pollEvents() async {
    if (_disposed || _polling || !running) return;
    _polling = true;
    try {
      final chunk = await channel.invokeMethod<String>('poll') ?? '';
      if (_disposed || chunk.isEmpty) return;
      _pendingOutput += chunk;
      final lines = _pendingOutput.split('\n');
      _pendingOutput = lines.removeLast();
      if (_pendingOutput.length > 1048576) _pendingOutput = '';
      for (final line in lines) {
        if (line.trim().isNotEmpty) _event(line);
      }
    } catch (_) {
      /* Android pushes events; older hosts have no poll method. */
    } finally {
      _polling = false;
    }
  }

  Future<void> start({
    String binary = '',
    int listenPort = defaultIperfPort,
  }) async {
    if (starting || _disposed) return;
    starting = true;
    running = false;
    error = null;
    port = listenPort;
    _monitor?.cancel();
    _events?.cancel();
    _pendingOutput = '';
    session.active = false;
    session.status = '等待其他设备连接';
    notifyListeners();
    channel.setMethodCallHandler((call) async {
      if (call.method == 'event' && call.arguments is String && !_disposed) {
        _event(call.arguments as String);
      }
      if (call.method == 'error' && !_disposed) {
        error = '服务端已停止：${call.arguments}';
        running = false;
        notifyListeners();
      }
    });
    try {
      await _nativeCommand('stop', timeout: const Duration(seconds: 5));
      if (_disposed) return;
      // Never mark another application's listener as our server.
      // Android destroys its isolated service asynchronously after unbinding.
      for (var attempt = 0; ; attempt++) {
        try {
          await _reservePort(port);
          break;
        } on SocketException catch (e) {
          if (!(isAddressInUse(e) || e.osError?.errorCode == 10013) ||
              attempt >= 30) {
            rethrow;
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
      if (_disposed) return;
      await _nativeCommand(
        'start',
        arguments: {'binary': binary.trim(), 'port': port},
        timeout: const Duration(seconds: 10),
      );
      if (_disposed) return;
      var ready = false;
      for (var attempt = 0; attempt < 20 && !_disposed; attempt++) {
        if (error != null) throw StateError(error!);
        final alive = await channel.invokeMethod<bool>('status') ?? false;
        if (!alive) throw StateError('iperf3 未能启动，请检查引擎、依赖文件或端口占用');
        if (await _probe(
          '127.0.0.1',
          port,
          const Duration(milliseconds: 300),
        )) {
          ready = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      if (_disposed) {
        await channel.invokeMethod<void>('stop');
        return;
      }
      if (!ready) throw StateError('服务端未就绪，请检查端口和引擎');
      if (error != null) throw StateError(error!);
      running = true;
      if (Platform.isWindows) {
        _events = Timer.periodic(
          const Duration(milliseconds: 100),
          (_) => _pollEvents(),
        );
      }
      _monitor = Timer.periodic(const Duration(seconds: 3), (_) => _check());
    } catch (e) {
      error = describeFailure(e, port);
      running = false;
      try {
        await channel.invokeMethod<void>('stop');
      } catch (_) {}
    } finally {
      starting = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _check() async {
    if (_checking || _disposed) return;
    _checking = true;
    try {
      if (await channel.invokeMethod<bool>('status') != true && !_disposed) {
        running = false;
        error = '服务端已退出，请点击重启';
        _monitor?.cancel();
        notifyListeners();
      }
    } catch (_) {
      if (!_disposed) {
        running = false;
        error = '无法读取服务端状态，请点击重启';
        _monitor?.cancel();
        notifyListeners();
      }
    } finally {
      _checking = false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    if (!_closed.isCompleted) _closed.complete();
    _events?.cancel();
    _monitor?.cancel();
    channel.setMethodCallHandler(null);
    unawaited(channel.invokeMethod<void>('stop').catchError((Object _) {}));
    super.dispose();
  }
}
