import 'package:flutter/material.dart';
import 'app.dart';

void main(List<String> arguments) {
  final value = arguments
      .where((a) => a.startsWith('--server-port='))
      .firstOrNull;
  final port = value == null ? null : int.tryParse(value.split('=').last);
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    LanIperfApp(
      serverPortOverride: port != null && port >= 1 && port <= 65535
          ? port
          : null,
    ),
  );
}
