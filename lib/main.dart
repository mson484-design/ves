import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:async';

List<CameraDescription> _cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    _cameras = await availableCameras();
  } catch (e) {
    debugPrint('카메라 장치 검색 실패: $e');
  }
  runApp(const VesApp());
}

class VesApp extends StatelessWidget {
  const VesApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VES 차량 안전 관제',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Colors.black,
      ),
      home: const VesMainScreen(),
    );
  }
}

class VesMainScreen extends StatefulWidget {
  const VesMainScreen({super.key});

  @override
  State<VesMainScreen> createState() => _VesMainScreenState();
}

class _VesMainScreenState extends State<VesMainScreen> {
  CameraController? _cameraController;
  final FlutterTts _tts = FlutterTts();
  double _speed = 0.0;
  String _statusText = "안전 운행 중";
  Color _statusColor = Colors.greenAccent;
  bool _isReady = false;

  Timer? _recoveryTimer;
  StreamSubscription<Position>? _posSub;
  StreamSubscription<AccelerometerEvent>? _sensorSub;
  DateTime _lastSensorUpdate = DateTime.now();

  @override
  void initState() {
    super.initState();
    _startSystem();
  }

  Future<void> _startSystem() async {
    await [Permission.camera, Permission.location].request();

    try {
      await _tts.setLanguage("ko-KR");
      await _tts.setSpeechRate(0.5);
    } catch (_) {}

    if (_cameras.isNotEmpty) {
      _cameraController = CameraController(
        _cameras[0],
        ResolutionPreset.medium,
        enableAudio: false,
      );
      try {
        await _cameraController!.initialize();
        if (mounted) setState(() => _isReady = true);
      } catch (e) {
        debugPrint("카메라 열기 실패: $e");
      }
    }

    try {
      _posSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 2,
        ),
      ).listen(
        (Position pos) {
          if (mounted) {
            setState(() {
              _speed = (pos.speed > 0 ? pos.speed : 0.0) * 3.6;
            });
          }
        },
        onError: (e) => debugPrint("GPS 오류: $e"),
      );
    } catch (e) {
      debugPrint("위치 센서 오류: $e");
    }

    _sensorSub = accelerometerEventStream().listen((AccelerometerEvent e) {
      final now = DateTime.now();
      if (now.difference(_lastSensorUpdate).inMilliseconds < 300) return;
      _lastSensorUpdate = now;

      if (e.x.abs() > 6.0 || e.y.abs() > 6.0 || (e.z.abs() - 9.8).abs() > 6.0) {
        _triggerAlert("급감속/충격 주의!", Colors.redAccent, "주의하세요");
      }
    });
  }

  void _triggerAlert(String text, Color color, String voiceMsg) {
    if (!mounted) return;

    setState(() {
      _statusText = text;
      _statusColor = color;
    });

    _tts.speak(voiceMsg);

    _recoveryTimer?.cancel();
    _recoveryTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() {
          _statusText = "안전 운행 중";
          _statusColor = Colors.greenAccent;
        });
      }
    });
  }

  @override
  void dispose() {
    _recoveryTimer?.cancel();
    _posSub?.cancel();
    _sensorSub?.cancel();
    _cameraController?.dispose();
    _tts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 1. 카메라 화면
          if (_isReady && _cameraController != null && _cameraController!.value.isInitialized)
            Center(child: CameraPreview(_cameraController!))
          else
            const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(color: Colors.greenAccent),
                  SizedBox(height: 16),
                  Text("뷔스 관제 시스템 준비 중...", style: TextStyle(color: Colors.white70, fontSize: 18)),
                ],
              ),
            ),

          // 2. 상단 와이드 직사각형 HUD 바 (화면 가로 꽉 채움)
          SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: Container(
                width: double.infinity,
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.75),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _statusColor, width: 2.5),
                  boxShadow: [
                    BoxShadow(
                      color: _statusColor.withOpacity(0.25),
                      blurRadius: 10,
                      spreadRadius: 1,
                    )
                  ],
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.shield, color: _statusColor, size: 26),
                        const SizedBox(width: 8),
                        Text(
                          _statusText,
                          style: TextStyle(
                            color: _statusColor,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    Row(
                      crossAxisAlignment: CrossAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(
                          _speed.toStringAsFixed(1),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 32,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Text(
                          'km/h',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
