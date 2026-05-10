import 'dart:io';

import 'package:camera/camera.dart';

import 'emotion_classifier.dart';
import 'video_emotion_analyzer.dart';

/// Headless FER pipeline: camera record → sampled frames → face crop + TFLite.
///
/// Call [WidgetsFlutterBinding.ensureInitialized] before use if there is no
/// running app (e.g. tests or isolates).
class EmotionDetectionService {
  EmotionDetectionService({
    this.modelAssetPath = 'assets/models/emotion_int8.tflite',
    this.resolution = ResolutionPreset.medium,
    this.enableAudio = true,
    this.preferFrontCamera = true,
  });

  /// TFLite asset registered in the host app's `pubspec.yaml`.
  final String modelAssetPath;

  final ResolutionPreset resolution;
  final bool enableAudio;
  final bool preferFrontCamera;

  EmotionClassifier? _classifier;
  CameraController? _camera;
  bool _recording = false;

  bool get isInitialized => _classifier != null && _camera != null;

  bool get isRecording => _recording;

  /// Exposed so host apps can attach [CameraPreview]; not required for record/analyze.
  CameraController? get cameraController => _camera;

  /// Loads the model and opens the camera. Idempotent until [dispose].
  Future<void> initialize() async {
    if (_classifier != null && _camera != null) return;

    _classifier ??= await EmotionClassifier.create(assetPath: modelAssetPath);
    await _openCamera();
  }

  Future<void> _openCamera() async {
    await _camera?.dispose();
    _camera = null;

    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      throw StateError('No camera found.');
    }

    CameraDescription desc = cameras.first;
    if (preferFrontCamera) {
      for (final c in cameras) {
        if (c.lensDirection == CameraLensDirection.front) {
          desc = c;
          break;
        }
      }
    }

    final controller = CameraController(
      desc,
      resolution,
      enableAudio: enableAudio,
    );
    await controller.initialize();
    _camera = controller;
  }

  /// Starts video recording. Initializes on first use.
  Future<void> start() async {
    await initialize();
    final cam = _camera;
    if (cam == null || !cam.value.isInitialized) {
      throw StateError('Camera is not ready.');
    }
    if (_recording) return;

    await cam.startVideoRecording();
    _recording = true;
  }

  /// Stops recording, runs the same analysis as the demo, deletes the temp file.
  ///
  /// [onRecordingStopped] runs after the file is finalized but before inference,
  /// e.g. to turn off a "recording" UI flag while analysis runs.
  Future<VideoAnalysisResult> stopAndAnalyze({
    void Function()? onRecordingStopped,
    void Function(int done, int total)? onAnalysisProgress,
  }) async {
    final cam = _camera;
    final clf = _classifier;
    if (cam == null || !cam.value.isInitialized || clf == null) {
      throw StateError('Service not initialized.');
    }
    if (!_recording) {
      throw StateError('Not recording.');
    }

    final xfile = await cam.stopVideoRecording();
    _recording = false;
    onRecordingStopped?.call();

    final path = xfile.path;
    try {
      return await VideoEmotionAnalyzer.analyze(
        classifier: clf,
        videoPath: path,
        onProgress: onAnalysisProgress ?? (_, __) {},
      );
    } finally {
      try {
        final f = File(path);
        if (await f.exists()) await f.delete();
      } catch (_) {
        /* best-effort */
      }
    }
  }

  /// Like [stopAndAnalyze] but returns label → percentage string, e.g. `'42%'`,
  /// over frames where a face was detected.
  Future<Map<String, String>> stop({
    void Function()? onRecordingStopped,
    void Function(int done, int total)? onAnalysisProgress,
  }) async {
    final analysis = await stopAndAnalyze(
      onRecordingStopped: onRecordingStopped,
      onAnalysisProgress: onAnalysisProgress,
    );
    return {
      for (final e in analysis.aggregate.entries)
        e.key: '${(e.value * 100).round()}%',
    };
  }

  /// Releases camera and model. Safe to call multiple times.
  Future<void> dispose() async {
    if (_recording) {
      try {
        await _camera?.stopVideoRecording();
      } catch (_) {
        /* best-effort */
      }
      _recording = false;
    }

    await _camera?.dispose();
    _camera = null;

    _classifier?.dispose();
    _classifier = null;
  }
}
