import 'dart:async';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:permission_handler/permission_handler.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: VesScreen(),
  ));
}

class VesScreen extends StatefulWidget {
  const VesScreen({super.key});

  @override
  State<VesScreen> createState() => _VesScreenState();
}

class _VesScreenState extends State<VesScreen> with WidgetsBindingObserver {
  CameraController? _cam;
  final FlutterTts _tts = FlutterTts();
  double _speed = 0.0;
  String _status = "정상 안전 운행 중";
  Color _color = Colors.greenAccent;
  bool _ready = false;
  bool _isSpeaking = false;

  Timer? _timer;
  StreamSubscription<Position>? _posSub;
  StreamSubscription<UserAccelerometerEvent>? _sensorSub;

  DateTime _lastSpeedUpdate = DateTime.now();
  DateTime _lastAlertTime = DateTime.now().subtract(const Duration(seconds: 20));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initAll();
  }

  Future<void> _initAll() async {
    // 1. 권한 요청
    await [Permission.camera, Permission.location].request();

    // 2. TTS 안전 초기화
    try {
      await _tts.setLanguage("ko-KR");
      await _tts.setSpeechRate(0.5);
      _tts.setCompletionHandler(() {
        _isSpeaking = false;
      });
    } catch (_) {}

    // 3. 카메라 초기화 (안정적인 해상도 설정)
    try {
      final cameras = await availableCameras();
      if (cameras.isNotEmpty) {
        final backCamera = cameras.firstWhere(
          (c) => c.lensDirection == CameraLensDirection.back,
          orElse: () => cameras.first,
        );
        _cam = CameraController(
          backCamera,
          ResolutionPreset.medium, // 고해상도로 인한 발열/멈춤 방지
          enableAudio: false,
        );
        await _cam!.initialize();
        if (mounted) setState(() => _ready = true);
      }
    } catch (e) {
      debugPrint("카메라 오류: $e");
    }

    // 4. GPS 속도 (0.5초당 1회만 화면 갱신하여 렉 방지)
    try {
      _posSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 1,
        ),
      ).listen((pos) {
        final now = DateTime.now();
        if (now.difference(_lastSpeedUpdate).inMilliseconds > 500) {
          _lastSpeedUpdate = now;
          if (mounted) {
            setState(() {
              _speed = (pos.speed > 0 ? pos.speed : 0.0) * 3.6;
            });
          }
        }
      });
    } catch (_) {}

    // 5. 충격/급감속 센서 (순수 거동 감지 + 8초 쿨타임)
    _sensorSub = userAccelerometerEventStream().listen((e) {
      final now = DateTime.now();
      if (now.difference(_lastAlertTime).inSeconds < 8) return;

      if (e.x.abs() > 11.0 || e.y.abs() > 11.0 || e.z.abs() > 11.0) {
        _lastAlertTime = now;

        if (!mounted) return;
        setState(() {
          _status = "급감속 / 충격 주의!";
          _color = Colors.redAccent;
        });

        if (!_isSpeaking) {
          _isSpeaking = true;
          _tts.speak("주의하세요");
        }

        _timer?.cancel();
        _timer = Timer(const Duration(seconds: 4), () {
          if (mounted) {
            setState(() {
              _status = "정상 안전 운행 중";
              _color = Colors.greenAccent;
            });
          }
        });
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 앱이 화면에서 벗어났다가 다시 올 때 카메라 멈춤 방지
    if (_cam == null || !_cam!.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      _cam?.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initAll();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _posSub?.cancel();
    _sensorSub?.cancel();
    _cam?.dispose();
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
          // 1. 전방 카메라 화면 (부드러운 프리뷰)
          if (_ready && _cam != null && _cam!.value.isInitialized)
            SizedBox.expand(
              child: FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: _cam!.value.previewSize?.height ?? 1,
                  height: _cam!.value.previewSize?.width ?? 1,
                  child: CameraPreview(_cam!),
                ),
              ),
            )
          else
            const Center(
              child: CircularProgressIndicator(color: Colors.greenAccent),
            ),

          // 2. 상단 우측: 미니멀 속도계
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Container(
                margin: const EdgeInsets.only(top: 10, right: 14),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.65),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white24, width: 1.5),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _speed.toStringAsFixed(1),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Text(
                      'km/h',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // 3. 하단 중앙: 안전 관제 문구 바 (아래 배치)
          SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                width: double.infinity,
                margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.78),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _color, width: 2),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      _color == Colors.greenAccent ? Icons.shield : Icons.warning_rounded,
                      color: _color,
                      size: 24,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      _status,
                      style: TextStyle(
                        color: _color,
                        fontSize: 18,
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
