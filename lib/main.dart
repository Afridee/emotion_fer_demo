import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'emotion_fer_controller.dart';
import 'video_emotion_analyzer.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const EmotionFerApp());
}

class EmotionFerApp extends StatelessWidget {
  const EmotionFerApp({super.key});

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF1A1A1A);
    return GetMaterialApp(
      title: 'FER emotion',
      debugShowCheckedModeBanner: false,
      initialBinding: BindingsBuilder(() {
        Get.put(EmotionFerController());
      }),
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: accent,
          brightness: Brightness.light,
          surface: const Color(0xFFF4F4F4),
        ),
        scaffoldBackgroundColor: const Color(0xFFF4F4F4),
        appBarTheme: const AppBarTheme(
          centerTitle: true,
          backgroundColor: Color(0xFFF4F4F4),
          foregroundColor: accent,
          elevation: 0,
          scrolledUnderElevation: 0,
        ),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final c = Get.find<EmotionFerController>();
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('FER · video')),
      body: Stack(
        fit: StackFit.expand,
        children: [
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Obx(() {
                if (c.loadingModel.value) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (c.loadError.value != null) {
                  return Center(
                    child: Text(
                      c.loadError.value!,
                      textAlign: TextAlign.center,
                    ),
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 12),
                    Text(
                      'emotion_int8.tflite',
                      style: textTheme.labelLarge?.copyWith(
                        letterSpacing: 0.4,
                        color: Colors.black54,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Expanded(child: _VideoPanel(c: c, textTheme: textTheme)),
                    const SizedBox(height: 16),
                  ],
                );
              }),
            ),
          ),
          Positioned.fill(child: _VideoAnalyzerOverlay(c: c)),
        ],
      ),
    );
  }
}

class _VideoAnalyzerOverlay extends StatelessWidget {
  const _VideoAnalyzerOverlay({required this.c});

  final EmotionFerController c;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      if (!c.videoAnalyzing.value) return const SizedBox.shrink();
      final pct = c.videoProgressTotal.value > 0
          ? (c.videoProgressDone.value / c.videoProgressTotal.value)
              .clamp(0.0, 1.0)
          : 0.0;

      return Material(
        color: Colors.black45,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 280),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    Text(
                      'Analyzing video',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${c.videoProgressDone.value} / ${c.videoProgressTotal.value} frames',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Colors.black54,
                          ),
                    ),
                    const SizedBox(height: 12),
                    LinearProgressIndicator(value: pct),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    });
  }
}

class _VideoPanel extends StatelessWidget {
  const _VideoPanel({required this.c, required this.textTheme});

  final EmotionFerController c;
  final TextTheme textTheme;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      if (c.cameraError.value != null) {
        return Center(
          child: Text(c.cameraError.value!, textAlign: TextAlign.center),
        );
      }
      if (c.cameraInitializing.value ||
          c.cameraController.value == null ||
          !c.cameraController.value!.value.isInitialized) {
        return const Center(child: CircularProgressIndicator());
      }

      final cam = c.cameraController.value!;
      final hasSummary = c.videoAnalysis.value != null &&
          !c.videoAnalyzing.value &&
          !c.videoRecording.value;

      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: hasSummary
                ? SingleChildScrollView(
                    child: _VideoAnalysisPanel(
                      c: c,
                      textTheme: textTheme,
                      analysis: c.videoAnalysis.value!,
                    ),
                  )
                : ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: AspectRatio(
                      aspectRatio: cam.value.aspectRatio,
                      child: CameraPreview(cam),
                    ),
                  ),
          ),
          if (c.videoRecording.value) ...[
            const SizedBox(height: 12),
            Text(
              'Recording… tap Stop',
              style: textTheme.titleSmall?.copyWith(color: Colors.red.shade800),
            ),
          ],
          const SizedBox(height: 16),
          if (!hasSummary)
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: (c.videoRecording.value ||
                            c.analyzing ||
                            c.loadError.value != null)
                        ? null
                        : c.startVideoRecording,
                    child: const Text('Start'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.tonal(
                    onPressed: (!c.videoRecording.value ||
                            c.analyzing ||
                            c.loadError.value != null)
                        ? null
                        : c.stopVideoRecordingAndAnalyze,
                    child: const Text('Stop'),
                  ),
                ),
              ],
            ),
        ],
      );
    });
  }
}

class _VideoAnalysisPanel extends StatelessWidget {
  const _VideoAnalysisPanel({
    required this.c,
    required this.textTheme,
    required this.analysis,
  });

  final EmotionFerController c;
  final TextTheme textTheme;
  final VideoAnalysisResult analysis;

  @override
  Widget build(BuildContext context) {
    final entries = analysis.aggregate.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Summary (vote share of winning label per frame)',
          style: textTheme.titleSmall?.copyWith(color: Colors.black54),
        ),
        const SizedBox(height: 12),
        ...entries.map(
          (e) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: [
                Expanded(
                  flex: 2,
                  child: Text(e.key, style: textTheme.titleSmall),
                ),
                Expanded(
                  flex: 3,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: e.value.clamp(0.0, 1.0),
                      minHeight: 8,
                      backgroundColor: Colors.black12,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 48,
                  child: Text(
                    '${(e.value * 100).round()}%',
                    style: textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                    textAlign: TextAlign.end,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        Text(
          'Processed frames (${analysis.frames.length})',
          style: textTheme.titleSmall?.copyWith(color: Colors.black54),
        ),
        const SizedBox(height: 8),
        ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: analysis.frames.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final f = analysis.frames[index];
            return ListTile(
              contentPadding:
                  const EdgeInsets.symmetric(vertical: 8, horizontal: 0),
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.memory(
                  f.thumbnailBytes,
                  width: 64,
                  height: 64,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                ),
              ),
              title: Text(
                f.result.label,
                style: textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: Text(
                '${(f.result.confidence * 100).toStringAsFixed(0)}% · '
                '${f.timeMs} ms · sample ${f.sampleIndex}',
                style: textTheme.bodySmall?.copyWith(color: Colors.black54),
              ),
            );
          },
        ),
        const SizedBox(height: 8),
        FilledButton.tonal(
          onPressed: (c.videoRecording.value || c.videoAnalyzing.value)
              ? null
              : c.clearVideoSummary,
          child: const Text('Record again'),
        ),
      ],
    );
  }
}
