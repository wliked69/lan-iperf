import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_iperf/discovery.dart';

void main() {
  test('CIDR honors subnet masks, omits network/broadcast and handles /31', () {
    final range = IPv4Range.parse('192.168.5.19/30');
    expect(range.toString(), '192.168.5.16/30');
    expect(range.hosts.toList(), ['192.168.5.17', '192.168.5.18']);
    expect(IPv4Range.parse('10.0.0.0/31').hosts.length, 2);
    expect(IPv4Range.parse('10.0.0.5/32').hosts.single, '10.0.0.5');
    expect(IPv4Range.parse('10.0.1.7/20').hosts.length, 4094);
    for (final text in [
      '192.168.1.0',
      '300.1.1.0/24',
      '10.0.0.0/16',
      'foo/24',
      '10.0.0.0/33',
    ]) {
      expect(() => IPv4Range.parse(text), throwsFormatException);
    }
  });
  test(
    'local networks distinguish private ranges and suggest bounded scopes',
    () {
      for (final ip in [
        '10.0.0.1',
        '172.16.0.1',
        '172.31.255.254',
        '192.168.0.1',
        '169.254.1.1',
      ]) {
        expect(LocalNetwork.isLanAddress(ip), isTrue);
      }
      for (final ip in ['127.0.0.1', '8.8.8.8', '172.15.0.1', '172.32.0.1']) {
        expect(LocalNetwork.isLanAddress(ip), isFalse);
      }
      expect(
        const LocalNetwork('Ethernet', '10.20.30.45', 16).suggestedRange,
        '10.20.30.0/24',
      );
      expect(
        const LocalNetwork('WiFi', '192.168.1.129', 25).suggestedRange,
        '192.168.1.128/25',
      );
    },
  );
  test(
    'scanner bounds concurrency, excludes own addresses and reports sorted devices',
    () async {
      var active = 0, peak = 0;
      final progress = <int>[];
      final scanner = LanScanner(
        probe: (host, port, timeout) async {
          active++;
          if (active > peak) peak = active;
          expect(port, 5202);
          await Future<void>.delayed(const Duration(milliseconds: 2));
          active--;
          return true;
        },
      );
      final devices = await scanner.scan(
        IPv4Range.parse('192.168.1.0/29'),
        5202,
        concurrency: 2,
        exclude: {'192.168.1.1'},
        onProgress: (done, total) {
          expect(total, 5);
          progress.add(done);
        },
      );
      expect(peak, 2);
      expect(devices.length, 5);
      expect(devices.first.host, '192.168.1.2');
      expect(progress.last, 5);
      expect(scanner.running, isFalse);
    },
  );
  test(
    'cancel prevents further work and late discoveries, then allows rescan',
    () async {
      final gate = Completer<bool>();
      var probes = 0;
      final scanner = LanScanner(
        probe: (_, _, _) {
          probes++;
          return gate.future;
        },
      );
      final result = scanner.scan(
        IPv4Range.parse('192.168.1.0/24'),
        5201,
        concurrency: 3,
        onFound: (_) => fail('Late result after cancel'),
      );
      scanner.cancel();
      gate.complete(true);
      expect(await result, isEmpty);
      expect(probes, 3);
      expect(scanner.running, isFalse);
      expect(
        (await scanner.scan(IPv4Range.parse('192.168.1.1/32'), 5201)).length,
        1,
      );
    },
  );
  test('plain listening port is not an iperf3 endpoint', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((socket) => socket.destroy());
    final port = server.port;
    final scanner = LanScanner();
    final range = IPv4Range.parse('127.0.0.1/32');
    expect(await scanner.scan(range, port), isEmpty);
    await subscription.cancel();
    await server.close();
    expect(await scanner.scan(range, port), isEmpty);
    expect(scanner.running, isFalse);
  });
  test(
    'iperf3 framed handshake is verified and aborted without data streams',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final finished = Completer<void>();
      final subscription = server.listen((socket) async {
        final input = StreamIterator(socket.expand((chunk) => chunk));
        Future<List<int>> read(int count) async {
          final values = <int>[];
          for (var i = 0; i < count; i++) {
            if (!await input.moveNext()) throw StateError('Unexpected EOF');
            values.add(input.current);
          }
          return values;
        }

        try {
          final cookie = await read(37);
          expect(cookie.last, 0);
          expect(
            ascii.decode(cookie.take(36).toList()),
            matches(RegExp(r'^[a-z2-7]{36}$')),
          );
          socket.add([9]);
          await socket.flush();
          final header = await read(4);
          final size = ByteData.sublistView(
            Uint8List.fromList(header),
          ).getUint32(0, Endian.big);
          expect(size, lessThan(1024));
          final parameters = jsonDecode(utf8.decode(await read(size))) as Map;
          expect(parameters['tcp'], true);
          expect(parameters['parallel'], 1);
          socket.add([10]);
          await socket.flush();
          expect(await read(1), [12]);
          finished.complete();
        } catch (e, stack) {
          finished.completeError(e, stack);
        } finally {
          socket.destroy();
          await input.cancel();
        }
      });
      final found = await LanScanner().scan(
        IPv4Range.parse('127.0.0.1/32'),
        server.port,
        timeout: const Duration(seconds: 2),
      );
      expect(found.single.host, '127.0.0.1');
      await finished.future.timeout(const Duration(seconds: 2));
      await subscription.cancel();
      await server.close();
    },
  );
  test('HTTP, TLS, echo and denial banners are filtered out', () async {
    for (final banner in [
      ascii.encode('HTTP/1.1 200 OK\r\n'),
      [22, 3, 3],
      [255],
      [9, 4],
    ]) {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((socket) async {
        socket.add(banner);
        await socket.flush();
        socket.destroy();
      });
      expect(
        await LanScanner().scan(IPv4Range.parse('127.0.0.1/32'), server.port),
        isEmpty,
      );
      await subscription.cancel();
      await server.close();
    }
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((socket) {
      socket.listen(
        socket.add,
        onDone: socket.destroy,
        onError: (_) => socket.destroy(),
      );
    });
    expect(
      await LanScanner().scan(IPv4Range.parse('127.0.0.1/32'), server.port),
      isEmpty,
    );
    await subscription.cancel();
    await server.close();
  });
  test('silent services time out and scanner can run again', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final peers = <Socket>[];
    final subscription = server.listen(peers.add);
    final scanner = LanScanner();
    final elapsed = Stopwatch()..start();
    expect(
      await scanner.scan(
        IPv4Range.parse('127.0.0.1/32'),
        server.port,
        timeout: const Duration(milliseconds: 100),
      ),
      isEmpty,
    );
    expect(elapsed.elapsed, lessThan(const Duration(seconds: 2)));
    expect(scanner.running, false);
    for (final peer in peers) {
      peer.destroy();
    }
    await subscription.cancel();
    await server.close();
  });
}
