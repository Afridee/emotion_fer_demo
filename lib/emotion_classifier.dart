import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

/// FER CNN (7 classes) with int8 I/O — matches labels used in `fertestcustom.py`.
class EmotionClassifier {
  EmotionClassifier._(this._interpreter, this._faceDetector);

  final Interpreter _interpreter;
  final FaceDetector _faceDetector;

  static const labels = [
    'Angry',
    'Disgust',
    'Fear',
    'Happy',
    'Sad',
    'Surprise',
    'Neutral',
  ];

  /// Fallback quantization (from `emotion_int8.tflite` export); used if [Tensor.params] is zero on some platforms.
  static const double fallbackInputScale = 0.03704935;
  static const int fallbackInputZeroPoint = 7;
  static const double fallbackOutputScale = 0.00390625;
  static const int fallbackOutputZeroPoint = -128;

  static Future<EmotionClassifier> create({
    String assetPath = 'assets/models/emotion_int8.tflite',
  }) async {
    final interpreter = await Interpreter.fromAsset(assetPath);
    final faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        performanceMode: FaceDetectorMode.accurate,
        minFaceSize: 0.12,
      ),
    );
    return EmotionClassifier._(interpreter, faceDetector);
  }

  void dispose() {
    _interpreter.close();
    unawaited(_faceDetector.close());
  }

  /// Detects the largest face with ML Kit, crops with margin, then runs [classify].
  ///
  /// Returns `null` if no face is found or the crop is invalid — callers should skip that frame.
  Future<EmotionResult?> classifyWithFaceCrop(Uint8List imageBytes) async {
    final decoded = img.decodeImage(imageBytes);
    if (decoded == null) {
      throw ArgumentError('Could not decode image');
    }

    final dir = await getTemporaryDirectory();
    final tmp = File(
      '${dir.path}/mlkit_face_${DateTime.now().microsecondsSinceEpoch}.png',
    );
    await tmp.writeAsBytes(img.encodePng(decoded));

    try {
      final faces = await _faceDetector.processImage(
        InputImage.fromFilePath(tmp.path),
      );

      if (faces.isEmpty) {
        return null;
      }

      Face best = faces.first;
      var bestArea = best.boundingBox.width * best.boundingBox.height;
      for (final f in faces.skip(1)) {
        final a = f.boundingBox.width * f.boundingBox.height;
        if (a > bestArea) {
          best = f;
          bestArea = a;
        }
      }

      final box = best.boundingBox;
      final margin =
          (math.max(box.width, box.height) * 0.15).round(); // padding around face

      final left = math.max(0, (box.left - margin).floor());
      final top = math.max(0, (box.top - margin).floor());
      final right = math.min(decoded.width, (box.right + margin).ceil());
      final bottom = math.min(decoded.height, (box.bottom + margin).ceil());

      final w = right - left;
      final h = bottom - top;
      if (w < 2 || h < 2) {
        return null;
      }

      final cropped = img.copyCrop(
        decoded,
        x: left,
        y: top,
        width: w,
        height: h,
      );
      final croppedBytes = Uint8List.fromList(img.encodePng(cropped));
      return classify(croppedBytes);
    } finally {
      try {
        if (tmp.existsSync()) tmp.deleteSync();
      } catch (_) {
        /* ignore */
      }
    }
  }

  /// Runs inference on raw image bytes (JPEG/PNG). Uses per-face-patch style 48×48 grayscale
  /// with per-image z-score (reasonable on-device proxy for training normalization).
  EmotionResult classify(Uint8List imageBytes) {
    final decoded = img.decodeImage(imageBytes);
    if (decoded == null) {
      throw ArgumentError('Could not decode image');
    }

    final gray = img.grayscale(decoded);
    final resized = img.copyResize(
      gray,
      width: 48,
      height: 48,
      interpolation: img.Interpolation.linear,
    );

    final floats = Float32List(48 * 48);
    var i = 0;
    var sum = 0.0;
    for (var y = 0; y < 48; y++) {
      for (var x = 0; x < 48; x++) {
        final lum = img.getLuminance(resized.getPixel(x, y)) / 255.0;
        floats[i++] = lum;
        sum += lum;
      }
    }
    final mean = sum / floats.length;
    var varSum = 0.0;
    for (var j = 0; j < floats.length; j++) {
      final d = floats[j] - mean;
      varSum += d * d;
    }
    final std = math.sqrt(varSum / floats.length) + 1e-6;
    for (var j = 0; j < floats.length; j++) {
      floats[j] = (floats[j] - mean) / std;
    }

    final inTensor = _interpreter.getInputTensor(0);
    var inScale = inTensor.params.scale;
    var inZp = inTensor.params.zeroPoint;
    if (inScale == 0) {
      inScale = fallbackInputScale;
      inZp = fallbackInputZeroPoint;
    }

    final input = List.generate(
      1,
      (_) => List.generate(
        48,
        (y) => List.generate(48, (x) {
          final f = floats[y * 48 + x];
          final q = ((f / inScale).round() + inZp).clamp(-128, 127).toInt();
          return [q];
        }),
      ),
    );

    final output = [List<int>.filled(7, 0)];

    _interpreter.run(input, output);

    final outTensor = _interpreter.getOutputTensor(0);
    var oScale = outTensor.params.scale;
    var oZp = outTensor.params.zeroPoint;
    if (oScale == 0) {
      oScale = fallbackOutputScale;
      oZp = fallbackOutputZeroPoint;
    }

    final logits = List<double>.generate(
      7,
      (k) => (output[0][k] - oZp) * oScale,
    );
    final probs = _softmax(logits);
    var best = 0;
    for (var k = 1; k < 7; k++) {
      if (probs[k] > probs[best]) best = k;
    }
    return EmotionResult(
      label: labels[best],
      confidence: probs[best],
      probabilities: List<double>.unmodifiable(probs),
    );
  }

  static List<double> _softmax(List<double> x) {
    final m = x.reduce(math.max);
    var s = 0.0;
    final e = List<double>.generate(x.length, (i) {
      final v = math.exp(x[i] - m);
      s += v;
      return v;
    });
    return e.map((v) => v / s).toList();
  }
}

class EmotionResult {
  const EmotionResult({
    required this.label,
    required this.confidence,
    required this.probabilities,
  });

  final String label;
  final double confidence;
  final List<double> probabilities;
}
