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

  StreamSubscription? _posSub;
  StreamSubscription? _sensorSub;

  @override
  void initState() {
    super.initState();
    _startSystem();
  }

  Future<void> _startSystem() async {
    // 1. 카메라 및 위치 권한 요청
    await [Permission.camera, Permission.location].request();

    // 2. 카메라 연결
    if (_cameras.isNotEmpty) {
      _cameraController = CameraController(
        _cameras[0],
        ResolutionPreset.high,
        enableAudio: false,
      );
      try {
        await _cameraController!.initialize();
        if (mounted) setState(() => _isReady = true);
      } catch (e) {
        debugPrint("카메라 열기 에러: $e");
      }
    }

    // 3. TTS 초기화
    await _tts.setLanguage("ko-KR");

    // 4. GPS 속도 측정
    _posSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 1,
      ),
    ).listen((Position pos) {
      if (mounted) {
        setState(() {
          _speed = (pos.speed > 0 ? pos.speed : 0.0) * 3.6;
        });
      }
    });

    // 5. 급가속/급감속 센서 감지
    _sensorSub = accelerometerEventStream().listen((AccelerometerEvent e) {
      if (e.x.abs() > 4.5 || e.y.abs() > 4.5) {
        if (mounted) {
          setState(() {
            _statusText = "급감속/충격 주의!";
            _statusColor = Colors.redAccent;
          });
        }
      }
    });
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _posSub?.cancel();
    _sensorSub?.cancel();
    _tts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 1. 후방/전방 카메라 실시간 프리뷰
          if (_isReady && _cameraController != null && _cameraController!.value.isInitialized)
            CameraPreview(_cameraController!)
          else
            const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(color: Colors.greenAccent),
                  SizedBox(height: 16),
                  Text("카메라 및 센서 연결 중...", style: TextStyle(color: Colors.white, fontSize: 18)),
                ],
              ),
            ),

          // 2. 상단 HUD 형태의 투명 관제 오버레이
          SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: Container(
                margin: const EdgeInsets.all(16),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.6),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: _statusColor, width: 2),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _statusText,
                      style: TextStyle(
                        color: _statusColor,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${_speed.toStringAsFixed(1)} km/h',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                      ),
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
