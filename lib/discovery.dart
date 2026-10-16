import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'model.dart';

class IPv4Range {
  IPv4Range._(this.network, this.prefix);
  final int network, prefix;
  static int parseAddress(String value) {
    final parts = value.split('.');
    if (parts.length != 4 ||
        parts.any((p) => !RegExp(r'^\d{1,3}$').hasMatch(p))) {
      throw const FormatException('请输入 IPv4 网段，例如 192.168.1.0/24');
    }
    final bytes = parts.map(int.parse).toList();
    if (bytes.any((b) => b > 255)) throw const FormatException('IPv4 地址无效');
    return bytes.fold(0, (address, byte) => address * 256 + byte);
  }

  static String formatAddress(int value) =>
      [24, 16, 8, 0].map((shift) => (value >> shift) & 255).join('.');
  factory IPv4Range.parse(String text) {
    final parts = text.trim().split('/');
    final prefix = parts.length == 2 ? int.tryParse(parts.last) : null;
    if (prefix == null || prefix < 20 || prefix > 32) {
      throw const FormatException('扫描范围支持 /20–/32，每次最多 4094 个地址');
    }
    final address = parseAddress(parts.first);
    final mask = 0xffffffff ^ ((1 << (32 - prefix)) - 1);
    return IPv4Range._(address & mask, prefix);
  }
  int get size => 1 << (32 - prefix);
  Iterable<String> get hosts sync* {
    final start = prefix < 31 ? 1 : 0;
    final stop = prefix < 31 ? size - 1 : size;
    for (var i = start; i < stop; i++) {
      yield formatAddress(network + i);
    }
  }

  @override
  String toString() => '${formatAddress(network)}/$prefix';
}

class LocalNetwork {
  const LocalNetwork(
    this.name,
    this.address,
    this.prefix, {
    this.preferred = false,
  });
  final String name, address;
  final int prefix;
  final bool preferred;
  String get suggestedRange =>
      IPv4Range.parse('$address/${math.max(prefix, 24)}').toString();
  bool get narrowed => prefix < 24;
  static bool isLanAddress(String address) {
    final value = IPv4Range.parseAddress(address);
    return (value >> 24) == 10 ||
        (value >> 16) == 0xc0a8 ||
        ((value >> 20) == 0xac1) ||
        (value >> 16) == 0xa9fe;
  }
}

class NetworkDiscovery {
  static const channel = MethodChannel('cn.lanperf/network');
  static Future<List<LocalNetwork>> networks() async {
    final rows = await channel.invokeListMethod<dynamic>('networks') ?? [];
    final result = <LocalNetwork>[];
    final seen = <String>{};
    for (final row in rows) {
      final map = Map<String, dynamic>.from(row as Map);
      final address = map['address'] as String;
      final prefix = map['prefix'] as int;
      if (prefix >= 0 &&
          prefix <= 32 &&
          LocalNetwork.isLanAddress(address) &&
          seen.add(address)) {
        result.add(
          LocalNetwork(
            map['name'] as String,
            address,
            prefix,
            preferred: map['preferred'] == true,
          ),
        );
      }
    }
    result.sort((a, b) => (b.preferred ? 1 : 0).compareTo(a.preferred ? 1 : 0));
    return result;
  }
}

typedef IperfProbe =
    Future<bool> Function(String host, int port, Duration timeout);

/// Confirms the iperf3 cookie + parameter-exchange state sequence.
/// No data stream is created and no bandwidth test is run.
class LanScanner {
  LanScanner({IperfProbe? probe}) : _probe = probe ?? probeIperf3;
  final IperfProbe _probe;
  bool _running = false, _cancelled = false;
  bool get running => _running;
  void cancel() {
    _cancelled = true;
  }

  static Future<bool> probeIperf3(
    String host,
    int port,
    Duration timeout,
  ) async {
    Socket? socket;
    StreamIterator<int>? response;
    final elapsed = Stopwatch()..start();
    Duration remaining() {
      final value = timeout - elapsed.elapsed;
      if (value <= Duration.zero) {
        throw TimeoutException('iperf3 handshake timed out');
      }
      return value;
    }

    try {
      socket = await Socket.connect(host, port, timeout: remaining());
      socket.setOption(SocketOption.tcpNoDelay, true);
      response = StreamIterator(socket.expand((chunk) => chunk));
      final random = math.Random.secure();
      const alphabet = 'abcdefghijklmnopqrstuvwxyz234567';
      final cookie = List.generate(
        36,
        (_) => alphabet[random.nextInt(alphabet.length)],
      ).join();
      socket.add([...ascii.encode(cookie), 0]); // COOKIE_SIZE = 37.
      await socket.flush().timeout(remaining());
      if (!await response.moveNext().timeout(remaining()) ||
          response.current != 9) {
        return false;
      }
      // PARAM_EXCHANGE (9): prove the peer understands iperf3's framed JSON.
      final parameters = utf8.encode(
        jsonEncode({
          'tcp': true,
          'omit': 0,
          'time': 1,
          'parallel': 1,
          'len': 131072,
          'num': 0,
          'blockcount': 0,
          'client_version': 'lan-iperf-discovery',
        }),
      );
      final header = ByteData(4)..setUint32(0, parameters.length, Endian.big);
      socket.add([...header.buffer.asUint8List(), ...parameters]);
      await socket.flush().timeout(remaining());
      if (!await response.moveNext().timeout(remaining()) ||
          response.current != 10) {
        return false;
      }
      // CREATE_STREAMS (10) confirms the protocol. Abort before creating streams.
      socket.add([12]); // CLIENT_TERMINATE.
      await socket.flush().timeout(remaining());
      return true;
    } on SocketException {
      return false;
    } on TimeoutException {
      return false;
    } finally {
      socket?.destroy();
      await response?.cancel();
    }
  }

  Future<List<Device>> scan(
    IPv4Range range,
    int port, {
    Set<String> exclude = const {},
    int concurrency = 24,
    Duration timeout = const Duration(milliseconds: 600),
    void Function(int completed, int total)? onProgress,
    void Function(Device)? onFound,
  }) async {
    if (_running) throw StateError('已有扫描正在运行');
    if (port < 1 ||
        port > 65535 ||
        concurrency < 1 ||
        concurrency > 64 ||
        timeout <= Duration.zero) {
      throw const FormatException('扫描参数无效');
    }
    _running = true;
    _cancelled = false;
    final hosts = range.hosts.where((h) => !exclude.contains(h)).toList();
    final devices = <Device>[];
    var next = 0, completed = 0;
    onProgress?.call(0, hosts.length);
    Future<void> worker() async {
      while (!_cancelled && next < hosts.length) {
        final host = hosts[next++];
        final available = await _probe(host, port, timeout);
        if (!_cancelled && available) {
          final device = Device('发现的设备 $host', host, port);
          devices.add(device);
          onFound?.call(device);
        }
        completed++;
        if (!_cancelled) onProgress?.call(completed, hosts.length);
      }
    }

    try {
      await Future.wait(
        List.generate(math.min(concurrency, hosts.length), (_) => worker()),
      );
      devices.sort(
        (a, b) => IPv4Range.parseAddress(
          a.host,
        ).compareTo(IPv4Range.parseAddress(b.host)),
      );
      return devices;
    } finally {
      _running = false;
    }
  }
}
