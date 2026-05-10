import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'emotion_detection_service.dart';
import 'video_emotion_analyzer.dart';

class EmotionFerController extends GetxController {
  final _service = EmotionDetectionService();

  final loadingModel = true.obs;
  final loadError = Rxn<String>();

  final cameraController = Rxn<CameraController>();
  final cameraInitializing = false.obs;
  final cameraError = Rxn<String>();

  final videoRecording = false.obs;
  final videoAnalyzing = false.obs;
  final videoProgressDone = 0.obs;
  final videoProgressTotal = 1.obs;
  final videoAnalysis = Rxn<VideoAnalysisResult>();

  bool get analyzing => videoAnalyzing.value;

  @override
  void onInit() {
    super.onInit();
    _initModel();
  }

  @override
  void onClose() {
    cameraController.value = null;
    unawaited(_service.dispose());
    super.onClose();
  }

  void _toast(String msg) {
    Get.snackbar('', msg, snackPosition: SnackPosition.BOTTOM, margin: const EdgeInsets.all(12));
  }

  Future<void> _initModel() async {
    cameraInitializing.value = true;
    cameraError.value = null;
    loadError.value = null;

    try {
      await _service.initialize();
      if (isClosed) return;
      cameraController.value = _service.cameraController;
      loadingModel.value = false;
      cameraInitializing.value = false;
    } catch (e) {
      if (isClosed) return;
      loadingModel.value = false;
      cameraInitializing.value = false;
      if (e is StateError && e.message.contains('No camera')) {
        cameraError.value = e.message;
      } else if (e is CameraException) {
        cameraError.value = 'Camera failed: ${e.runtimeType}: $e';
      } else {
        loadError.value = e.toString();
      }
    }
  }

  Future<void> startVideoRecording() async {
    if (cameraController.value == null ||
        !cameraController.value!.value.isInitialized ||
        videoRecording.value ||
        videoAnalyzing.value ||
        loadError.value != null) {
      return;
    }
    try {
      await _service.start();
      if (isClosed) return;
      videoRecording.value = true;
    } catch (e) {
      _toast('Could not start recording: $e');
    }
  }

  Future<void> stopVideoRecordingAndAnalyze() async {
    if (cameraController.value == null ||
        !cameraController.value!.value.isInitialized ||
        !_service.isRecording) {
      return;
    }
    if (!videoRecording.value) return;

    videoAnalysis.value = null;

    VideoAnalysisResult? analysis;
    try {
      analysis = await _service.stopAndAnalyze(
        onRecordingStopped: () {
          if (isClosed) return;
          videoRecording.value = false;
          videoAnalyzing.value = true;
          videoProgressDone.value = 0;
          videoProgressTotal.value = 1;
        },
        onAnalysisProgress: (done, total) {
          if (isClosed) return;
          videoProgressDone.value = done;
          videoProgressTotal.value = total > 0 ? total : 1;
        },
      );
    } catch (e) {
      if (!isClosed) {
        videoRecording.value = _service.isRecording;
        _toast('Video analysis failed: $e');
      }
    } finally {
      if (!isClosed) {
        videoAnalyzing.value = false;
        if (analysis != null) {
          videoAnalysis.value = analysis;
        }
      }
    }
  }

  void clearVideoSummary() {
    videoAnalysis.value = null;
  }
}
