import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

import 'emotion_classifier.dart';

/// One sampled frame that made it through face detection + classification.
class ProcessedVideoFrame {
  const ProcessedVideoFrame({
    required this.sampleIndex,
    required this.timeMs,
    required this.thumbnailBytes,
    required this.result,
  });

  /// 1-based index in the sampling loop (not all samples produce a frame here).
  final int sampleIndex;
  final int timeMs;
  final Uint8List thumbnailBytes;
  final EmotionResult result;
}

/// Aggregate emotion vote shares plus per-frame detail for the summary UI.
///
/// [aggregate] values are fractions from 0 to 1: fraction of processed frames where that
/// emotion won the argmax over softmax (ties broken by lower label index).
class VideoAnalysisResult {
  const VideoAnalysisResult({
    required this.aggregate,
    required this.frames,
  });

  final Map<String, double> aggregate;
  final List<ProcessedVideoFrame> frames;
}

/// Samples recorded video (~1/3 of estimated frames) and builds aggregate vote shares across frames.
///
/// Uses [nominalFps] as an estimate of captured frame rate (aligned with [ResolutionPreset.medium]).
/// [VideoThumbnail.thumbnailData] and TFLite use platform APIs and must run on the main isolate;
/// callers should [await Future.delayed(Duration.zero)] between progress updates so the UI can paint.
class VideoEmotionAnalyzer {
  VideoEmotionAnalyzer._();

  /// Typical rate for HD/medium presets on phones; feeds sample-count estimate only.
  static const int nominalFps = 24;

  /// Runs thumbnail extraction + [EmotionClassifier.classifyWithFaceCrop] sequentially.
  /// Frames with no detectable face (or invalid crop) are omitted from the vote tally.
  ///
  /// [onProgress]: `done` in `0…total`, updated after each sample attempt completes.
  static Future<VideoAnalysisResult> analyze({
    required EmotionClassifier classifier,
    required String videoPath,
    required void Function(int done, int total) onProgress,
  }) async {
    final controller = VideoPlayerController.file(File(videoPath));
    await controller.initialize();
    try {
      final durationMs = controller.value.duration.inMilliseconds;
      if (durationMs <= 0) {
        throw StateError('Video duration is unavailable or zero.');
      }

      final durationSec = durationMs / 1000.0;
      final estimatedFrames = (durationSec * nominalFps).round();
      final sampleCount = math.max(1, estimatedFrames ~/ 3);

      final votes = List<int>.filled(EmotionClassifier.labels.length, 0);
      var validSamples = 0;
      final processedFrames = <ProcessedVideoFrame>[];

      for (var i = 0; i < sampleCount; i++) {
        final hi = math.max(0, durationMs - 1);
        final timeMs = (((i + 0.5) / sampleCount) * durationMs)
            .round()
            .clamp(0, hi)
            .toInt();

        Uint8List? thumb;
        try {
          thumb = await VideoThumbnail.thumbnailData(
            video: videoPath,
            imageFormat: ImageFormat.PNG,
            timeMs: timeMs,
            quality: 80,
          );
        } catch (_) {
          thumb = null;
        }

        if (thumb != null && thumb.isNotEmpty) {
          try {
            final r = await classifier.classifyWithFaceCrop(thumb);
            if (r != null) {
              validSamples++;
              var bestIdx = 0;
              for (var k = 1; k < r.probabilities.length; k++) {
                if (r.probabilities[k] > r.probabilities[bestIdx]) {
                  bestIdx = k;
                }
              }
              votes[bestIdx]++;
              processedFrames.add(
                ProcessedVideoFrame(
                  sampleIndex: i + 1,
                  timeMs: timeMs,
                  thumbnailBytes: Uint8List.fromList(thumb),
                  result: r,
                ),
              );
            }
          } catch (_) {
            // Skip frames that decode or classify poorly.
          }
        }

        onProgress(i + 1, sampleCount);
        await Future<void>.delayed(Duration.zero);
      }

      if (validSamples == 0) {
        throw StateError('No frames could be analyzed.');
      }

      final aggregate = {
        for (var j = 0; j < EmotionClassifier.labels.length; j++)
          EmotionClassifier.labels[j]: votes[j] / validSamples,
      };

      return VideoAnalysisResult(
        aggregate: aggregate,
        frames: processedFrames,
      );
    } finally {
      await controller.dispose();
    }
  }
}
