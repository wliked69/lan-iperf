import 'dart:ui' show ImageByteFormat;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_iperf/chart.dart';
import 'package:lan_iperf/model.dart';

void main() {
  test('chart follows measured time and rolls the latest minute', () {
    final initial = ChartTimeRange.forData(0, windowSeconds: 60);
    expect(initial.span, greaterThan(0));
    final range = ChartTimeRange.forData(8, windowSeconds: 60);
    expect(range.start, 0);
    expect(range.end, 8);
    final rolling = ChartTimeRange.forData(99999, windowSeconds: 60);
    expect(rolling.start, 99939);
    expect(rolling.end, 99999);
    expect(rolling.span, 60);
  });
  testWidgets(
    '99999 second configuration does not squeeze actual chart to left',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(640, 360));
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: key,
            child: const Scaffold(
              body: SpeedChart(
                samples: [Sample(.1, 40), Sample(8, 50)],
                duration: 99999,
                direction: Direction.upload,
                showLatency: false,
                windowSeconds: 60,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final rightmost = await tester.runAsync(() async {
        final image =
            await (key.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = (await image.toByteData(
          format: ImageByteFormat.rawRgba,
        ))!;
        var farthest = 0;
        for (var y = 55; y < 240; y++) {
          for (var x = 52; x < image.width; x++) {
            final i = (y * image.width + x) * 4;
            if (bytes.getUint8(i) == 56 &&
                bytes.getUint8(i + 1) == 220 &&
                bytes.getUint8(i + 2) == 192 &&
                x > farthest) {
              farthest = x;
            }
          }
        }
        image.dispose();
        return farthest;
      });
      expect(rightmost, greaterThan(600));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.binding.setSurfaceSize(null);
    },
  );
  testWidgets(
    'download phase has no upload pixels or legend, upload appears only when started',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(640, 360));
      final key = GlobalKey();
      const download = [
        Sample(.1, 0, downloadMbps: 80, uploadActive: false),
        Sample(.2, 0, downloadMbps: 90, uploadActive: false),
      ];
      Future<void> render(List<Sample> samples) async {
        await tester.pumpWidget(
          MaterialApp(
            home: RepaintBoundary(
              key: key,
              child: Scaffold(
                body: SpeedChart(
                  samples: samples,
                  duration: 2,
                  direction: Direction.downloadThenUpload,
                  showLatency: false,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      Future<(int, int)> colors() async {
        return (await tester.runAsync(() async {
          final image =
              await (key.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ImageByteFormat.rawRgba);
          var upload = 0, down = 0;
          for (var i = 0; i < bytes!.lengthInBytes; i += 4) {
            if (bytes.getUint8(i) == 56 &&
                bytes.getUint8(i + 1) == 220 &&
                bytes.getUint8(i + 2) == 192) {
              upload++;
            }
            if (bytes.getUint8(i) == 104 &&
                bytes.getUint8(i + 1) == 169 &&
                bytes.getUint8(i + 2) == 255) {
              down++;
            }
          }
          image.dispose();
          return (upload, down);
        }))!;
      }

      await render(download);
      expect(find.text('━ 上传 Mbps'), findsNothing);
      final first = await colors();
      expect(first.$1, 0);
      expect(first.$2, greaterThan(0));
      await render([...download, const Sample(1.1, 40), const Sample(1.2, 50)]);
      expect(find.text('━ 上传 Mbps'), findsOneWidget);
      expect((await colors()).$1, greaterThan(0));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.binding.setSurfaceSize(null);
    },
  );
}
