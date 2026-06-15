import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import '../../services/triangle_video_recording_support.dart';

class TriangleVideoRecorderSheet extends StatefulWidget {
  const TriangleVideoRecorderSheet({
    super.key,
    required this.onSubmit,
  });

  final Future<bool> Function(List<int> bytes, String filename) onSubmit;

  @override
  State<TriangleVideoRecorderSheet> createState() => _TriangleVideoRecorderSheetState();
}

class _TriangleVideoRecorderSheetState extends State<TriangleVideoRecorderSheet> {
  final rtc.RTCVideoRenderer _renderer = rtc.RTCVideoRenderer();
  rtc.MediaStream? _localStream;
  rtc.MediaRecorder? _recorder;
  Timer? _ticker;
  String? _recordingPath;
  bool _cameraLoading = true;
  bool _recording = false;
  bool _busy = false;
  bool _isFrontCamera = true;
  int _elapsedSeconds = 0;
  String? _error;
  bool _rendererInitialized = false;

  static const int _maxDurationSeconds = 30;
  bool get _usesNativeRecorder => usesNativeTriangleVideoRecorder;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    unawaited(_disposeRecorder());
    super.dispose();
  }

  Future<void> _initialize() async {
    if (!isTriangleVideoRecordingSupported) {
      setState(() {
        _cameraLoading = false;
        _error = _unsupportedPlatformMessage;
      });
      return;
    }
    if (mounted) {
      setState(() {
        _cameraLoading = true;
        _error = null;
      });
    }
    try {
      if (!_rendererInitialized) {
        await _renderer.initialize();
        _rendererInitialized = true;
      }
      final stream = await rtc.navigator.mediaDevices.getUserMedia(
        <String, dynamic>{
          'audio': true,
          'video': <String, dynamic>{
            'facingMode': 'user',
            'mandatory': <String, dynamic>{
              'minWidth': '720',
              'minHeight': '1280',
              'minFrameRate': '24',
            },
            'optional': <dynamic>[],
          },
        },
      );
      _localStream = stream;
      _renderer.srcObject = stream;
      if (!mounted) {
        return;
      }
      setState(() {
        _cameraLoading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _cameraLoading = false;
        _error = 'Could not open the front camera. $error';
      });
    }
  }

  Future<void> _startRecording() async {
    final stream = _localStream;
    if ((_usesNativeRecorder ? false : stream == null) || _busy) {
      return;
    }
    try {
      String? path;
      rtc.MediaRecorder? recorder;
      if (_usesNativeRecorder) {
        await _disposeLocalPreviewStream();
        path = await startNativeTriangleVideoRecording();
      } else {
        recorder = rtc.MediaRecorder(albumName: 'Kaftar');
      }
      if (kIsWeb) {
        final webRecorder = recorder!;
        final webStream = stream!;
        webRecorder.startWeb(
          webStream,
          mimeType: 'video/webm',
        );
      } else if (!_usesNativeRecorder) {
        final nativeRecorder = recorder!;
        final nativeStream = stream!;
        final track =
            nativeStream.getVideoTracks().firstWhere((item) => item.kind == 'video');
        path = await createTriangleVideoTempPath();
        await nativeRecorder.start(
          path,
          videoTrack: track,
          audioChannel: rtc.RecorderAudioChannel.INPUT,
        );
      }
      _ticker?.cancel();
      _ticker = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted) {
          return;
        }
        final nextValue = _elapsedSeconds + 1;
        if (nextValue >= _maxDurationSeconds) {
          unawaited(_stopAndSend());
          return;
        }
        setState(() {
          _elapsedSeconds = nextValue;
        });
      });
      setState(() {
        _recorder = recorder;
        _recordingPath = path;
        _recording = true;
        _elapsedSeconds = 0;
        _error = null;
      });
    } catch (error) {
      setState(() {
        _error = 'Could not start recording. $error';
      });
    }
  }

  Future<void> _stopAndSend() async {
    final recorder = _recorder;
    if ((!_usesNativeRecorder && recorder == null) || (_usesNativeRecorder && _recordingPath == null) || _busy) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    _ticker?.cancel();
    try {
      final String? recordedPath;
      if (_usesNativeRecorder) {
        recordedPath = await stopNativeTriangleVideoRecording();
      } else if (kIsWeb) {
        recordedPath = await recorder!.stop() as String;
      } else {
        recordedPath = _recordingPath;
      }
      if (recordedPath == null || recordedPath.isEmpty) {
        throw StateError('Recorder did not return a saved video.');
      }
      final bytes = await readTriangleVideoBytes(recordedPath);
      final sent = await widget.onSubmit(
        bytes,
        'triangle-${DateTime.now().millisecondsSinceEpoch}.${kIsWeb ? 'webm' : 'mp4'}',
      );
      await deleteTriangleVideoFile(recordedPath);
      _recordingPath = null;
      _recorder = null;
      _recording = false;
      _elapsedSeconds = 0;
      if (!mounted) {
        return;
      }
      if (sent) {
        Navigator.of(context).pop();
        return;
      }
      setState(() {
        _busy = false;
        _error = 'The video was recorded, but sending failed.';
      });
      if (_usesNativeRecorder) {
        await _initialize();
      }
    } catch (error) {
      setState(() {
        _busy = false;
        _error = 'Could not finish recording. $error';
      });
      if (_usesNativeRecorder) {
        await _initialize();
      }
    }
  }

  Future<void> _switchCamera() async {
    final stream = _localStream;
    if (stream == null || _busy || _recording) {
      return;
    }
    try {
      final track = stream.getVideoTracks().firstWhere((item) => item.kind == 'video');
      await rtc.Helper.switchCamera(track);
      setState(() {
        _isFrontCamera = !_isFrontCamera;
      });
    } catch (error) {
      setState(() {
        _error = 'Could not switch the camera. $error';
      });
    }
  }

  Future<void> _disposeRecorder() async {
    _ticker?.cancel();
    try {
      final stopResult = _usesNativeRecorder
          ? (_recording ? await stopNativeTriangleVideoRecording() : null)
          : await _recorder?.stop();
      if (kIsWeb && stopResult is String) {
        await deleteTriangleVideoFile(stopResult);
      }
      if (_usesNativeRecorder && stopResult is String) {
        await deleteTriangleVideoFile(stopResult);
      }
    } catch (_) {}
    final path = _recordingPath;
    _recordingPath = null;
    _recorder = null;
    if (path != null) {
      await deleteTriangleVideoFile(path);
    }
    final stream = _localStream;
    _localStream = null;
    if (stream != null) {
      for (final track in stream.getTracks()) {
        track.stop();
      }
      await stream.dispose();
    }
    _renderer.srcObject = null;
    if (_rendererInitialized) {
      await _renderer.dispose();
      _rendererInitialized = false;
    }
  }

  Future<void> _disposeLocalPreviewStream() async {
    final stream = _localStream;
    _localStream = null;
    if (stream != null) {
      for (final track in stream.getTracks()) {
        track.stop();
      }
      await stream.dispose();
    }
    _renderer.srcObject = null;
  }

  String get _timerLabel {
    final minutes = (_elapsedSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (_elapsedSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  String get _unsupportedPlatformMessage {
    return 'Triangle video recording is available on Android, iPhone, macOS, Windows, and web builds.';
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        decoration: const BoxDecoration(
          color: Color(0xFF091018),
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0xFF294154),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Triangle Video',
                          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                                color: const Color(0xFFF5F7FB),
                                fontWeight: FontWeight.w800,
                              ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _recording
                              ? 'Recording from the front camera. Tap stop to send.'
                              : 'Tap start to record a triangle video from the selfie camera.',
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: const Color(0xFF94A7B5),
                              ),
                        ),
                      ],
                    ),
                  ),
                  if (_recording)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                      decoration: BoxDecoration(
                        color: const Color(0xFF23121A),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: const Color(0xFF5A2035)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 9,
                            height: 9,
                            decoration: const BoxDecoration(
                              color: Color(0xFFFF5E78),
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _timerLabel,
                            style: const TextStyle(
                              color: Color(0xFFFFD5DE),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 18),
              Expanded(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Color(0xFF0F2433),
                        Color(0xFF0A1924),
                        Color(0xFF142B37),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(color: const Color(0xFF1E3949)),
                  ),
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: IgnorePointer(
                          child: Opacity(
                            opacity: 0.18,
                            child: CustomPaint(
                              painter: _TriangleAuraPainter(),
                            ),
                          ),
                        ),
                      ),
                      Center(
                        child: AspectRatio(
                          aspectRatio: 0.86,
                          child: _TriangleCameraPreview(
                            renderer: _renderer,
                            isLoading: _cameraLoading,
                            mirror: _isFrontCamera,
                            error: _error,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _busy ? null : () => Navigator.of(context).pop(),
                      child: const Text('Close'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  IconButton.filledTonal(
                    onPressed: (_cameraLoading || _busy) ? null : _switchCamera,
                    icon: const Icon(Icons.cameraswitch_rounded),
                    tooltip: 'Switch camera',
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: _recording ? const Color(0xFFE55C74) : const Color(0xFF59D0C2),
                        foregroundColor: const Color(0xFF071116),
                      ),
                      onPressed: (_cameraLoading ||
                              _busy ||
                              (!_usesNativeRecorder && _error != null && _localStream == null))
                          ? null
                          : (_recording ? _stopAndSend : _startRecording),
                      child: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(_recording ? 'Stop & Send' : 'Start'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Limit: ${_maxDurationSeconds}s. Recording keeps the triangle shape in chat, and playback stays inside the app.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF6F8796),
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TriangleCameraPreview extends StatelessWidget {
  const _TriangleCameraPreview({
    required this.renderer,
    required this.isLoading,
    required this.mirror,
    required this.error,
  });

  final rtc.RTCVideoRenderer renderer;
  final bool isLoading;
  final bool mirror;
  final String? error;

  @override
  Widget build(BuildContext context) {
    return ClipPath(
      clipper: _PreviewTriangleClipper(),
      child: Container(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF295C75), Color(0xFF10222C)],
          ),
          border: Border.all(color: const Color(0x6689EEDE), width: 1.4),
          boxShadow: const [
            BoxShadow(
              color: Color(0x4007F0D8),
              blurRadius: 28,
              spreadRadius: -10,
              offset: Offset(0, 12),
            ),
          ],
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (!isLoading && error == null)
              rtc.RTCVideoView(
                renderer,
                mirror: mirror,
                objectFit: rtc.RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
              ),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      const Color(0x00101822),
                      const Color(0x00101822),
                      const Color(0xC9101822),
                    ],
                    stops: const [0.0, 0.5, 1.0],
                  ),
                ),
              ),
            ),
            Positioned(
              top: 16,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xCC071116),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: const Color(0xFF2D5568)),
                  ),
                  child: const Text(
                    'SELFIE TRIANGLE',
                    style: TextStyle(
                      color: Color(0xFFE9FBFF),
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
              ),
            ),
            if (isLoading)
              const Center(
                child: CircularProgressIndicator(strokeWidth: 2.4),
              )
            else if (error != null)
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: Text(
                    error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xFFE4EDF4),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PreviewTriangleClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    return Path()
      ..moveTo(size.width / 2, 0)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}

class _TriangleAuraPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = const Color(0x66A7FFF3);
    final path = Path()
      ..moveTo(size.width * 0.5, size.height * 0.06)
      ..lineTo(size.width * 0.82, size.height * 0.7)
      ..lineTo(size.width * 0.18, size.height * 0.7)
      ..close();
    canvas.drawPath(path, paint);
    canvas.drawCircle(
      Offset(size.width * 0.5, size.height * 0.42),
      size.width * 0.26,
      Paint()
        ..color = const Color(0x2217F0D7)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 36),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
