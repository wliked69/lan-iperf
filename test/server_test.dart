import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_iperf/server.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <String>[];
  var alive = true;
  setUp(() {
    calls.clear();
    alive = true;
    messenger.setMockMethodCallHandler(IperfServerController.channel, (
      call,
    ) async {
      calls.add(call.method);
      return call.method == 'status' ? alive : null;
    });
  });
  tearDown(
    () =>
        messenger.setMockMethodCallHandler(IperfServerController.channel, null),
  );

  Future<int> unusedPort() async {
    final socket = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  test(
    'starts listener, confirms iperf3 readiness and supports restart',
    () async {
      final server = IperfServerController(
        readinessProbe: (_, _, _) async => true,
      );
      try {
        final port = await unusedPort();
        await server.start(listenPort: port);
        expect(server.running, isTrue, reason: server.error);
        expect(server.error, isNull);
        expect(server.port, port);
        expect(calls, ['stop', 'start', 'status']);
        await server.start(listenPort: port);
        expect(server.running, isTrue, reason: server.error);
        expect(calls.where((c) => c == 'start'), hasLength(2));
      } finally {
        server.dispose();
      }
      await Future<void>.delayed(Duration.zero);
      expect(calls.last, 'stop');
    },
  );

  test('occupied port never starts or adopts an unrelated service', () async {
    final occupied = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    final server = IperfServerController(
      readinessProbe: (_, _, _) async => true,
    );
    try {
      await server.start(listenPort: occupied.port);
      expect(server.running, isFalse);
      expect(server.error, contains('端口'));
      expect(calls, isNot(contains('start')));
    } finally {
      server.dispose();
      await occupied.close();
    }
  });

  test(
    'restart waits for the old Android listener to release its port',
    () async {
      final server = IperfServerController(
        readinessProbe: (_, _, _) async => true,
      );
      final port = await unusedPort();
      await server.start(listenPort: port);
      final old = await ServerSocket.bind(InternetAddress.anyIPv4, port);
      final release = Future<void>.delayed(
        const Duration(milliseconds: 50),
        () async {
          await old.close();
        },
      );
      try {
        await server.start(listenPort: port);
        await release;
        expect(server.running, isTrue, reason: server.error);
        expect(server.error, isNull);
      } finally {
        server.dispose();
      }
    },
  );

  test(
    'fresh controller waits for a stale worker even when running was false',
    () async {
      final occupied = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
      final port = occupied.port;
      var released = false;
      messenger.setMockMethodCallHandler(IperfServerController.channel, (
        call,
      ) async {
        calls.add(call.method);
        if (call.method == 'stop' && !released) {
          released = true;
          Future<void>.delayed(
            const Duration(milliseconds: 150),
            occupied.close,
          );
        }
        return call.method == 'status' ? true : null;
      });
      final server = IperfServerController(
        readinessProbe: (_, _, _) async => true,
      );
      try {
        expect(server.running, isFalse);
        await server.start(listenPort: port);
        expect(server.running, isTrue, reason: server.error);
        expect(server.error, isNull);
        expect(calls, contains('start'));
      } finally {
        server.dispose();
        await occupied.close();
      }
    },
  );

  test('permission denial is not reported as an occupied port', () async {
    final server = IperfServerController(
      readinessProbe: (_, _, _) async => true,
      reservePort: (_) async => throw const SocketException(
        'Permission denied',
        osError: OSError('Permission denied', 13),
      ),
    );
    try {
      await server.start();
      expect(server.running, isFalse);
      expect(server.error, contains('权限'));
      expect(server.error, contains('13'));
      expect(server.error, isNot(contains('占用')));
      expect(calls, isNot(contains('start')));
    } finally {
      server.dispose();
    }
  });

  test('native failure message is shown directly without Bad state', () async {
    messenger.setMockMethodCallHandler(IperfServerController.channel, (
      call,
    ) async {
      if (call.method == 'start') {
        throw PlatformException(code: 'SERVER', message: '旧服务端尚未退出');
      }
      return null;
    });
    final server = IperfServerController(reservePort: (_) async {});
    try {
      await server.start();
      expect(server.error, contains('旧服务端尚未退出'));
      expect(server.error, isNot(contains('Bad state')));
      expect(server.error, isNot(contains('占用')));
    } finally {
      server.dispose();
    }
  });

  test('readiness failures do not expose a StateError wrapper', () async {
    final server = IperfServerController(reservePort: (_) async {});
    alive = false;
    try {
      await server.start();
      expect(server.error, contains('未能启动'));
      expect(server.error, isNot(contains('Bad state')));
    } finally {
      server.dispose();
    }
  });

  test('exited native process is never reported as ready', () async {
    alive = false;
    final server = IperfServerController(
      readinessProbe: (_, _, _) async => true,
    );
    try {
      await server.start(listenPort: await unusedPort());
      expect(server.running, isFalse);
      expect(server.starting, isFalse);
      expect(server.error, contains('未能启动'));
      expect(calls.last, 'stop');
    } finally {
      server.dispose();
    }
  });
}
