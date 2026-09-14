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

class _VesScreenState extends State<VesScreen> {
  CameraController? _cam;
  final FlutterTts _tts = FlutterTts();
  double _speed = 0.0;
  String _status = "정상 안전 운행 중";
  Color _color = Colors.greenAccent;
  bool _ready = false;

  Timer? _timer;
  StreamSubscription<Position>? _posSub;
  StreamSubscription<UserAccelerometerEvent>? _sensorSub;

  DateTime _lastAlertTime = DateTime.now().subtract(const Duration(seconds: 20));
  DateTime _lastCheck = DateTime.now();

  @override
  void initState() {
    super.initState();
    _initAll();
  }

  Future<void> _initAll() async {
    await [Permission.camera, Permission.location].request();

    try {
      await _tts.setLanguage("ko-KR");
      await _tts.setSpeechRate(0.5);
    } catch (_) {}

    try {
      final cameras = await availableCameras();
      if (cameras.isNotEmpty) {
        final backCamera = cameras.firstWhere(
          (c) => c.lensDirection == CameraLensDirection.back,
          orElse: () => cameras.first,
        );
        _cam = CameraController(
          backCamera,
          ResolutionPreset.high,
          enableAudio: false,
        );
        await _cam!.initialize();
        if (mounted) setState(() => _ready = true);
      }
    } catch (e) {
      debugPrint("카메라 오류: $e");
    }

    try {
      _posSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 1,
        ),
      ).listen((pos) {
        if (mounted) {
          setState(() {
            _speed = (pos.speed > 0 ? pos.speed : 0.0) * 3.6;
          });
        }
      });
    } catch (_) {}

    // 중력 제외 순수 가속도 센서 (반복 알림 및 거짓 경보 원천 차단)
    _sensorSub = userAccelerometerEventStream().listen((e) {
      final now = DateTime.now();
      if (now.difference(_lastCheck).inMilliseconds < 300) return;
      _lastCheck = now;

      if (now.difference(_lastAlertTime).inSeconds < 8) return;

      if (e.x.abs() > 12.0 || e.y.abs() > 12.0 || e.z.abs() > 12.0) {
        _lastAlertTime = now;

        if (!mounted) return;
        setState(() {
          _status = "급감속 / 충격 주의!";
          _color = Colors.redAccent;
        });

        _tts.speak("주의하세요");

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
  void dispose() {
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
          // 1. 실시간 전방 카메라 (화면 전체 꽉 채움)
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

          // 2. 상단: 군더더기 없는 미니멀 속도계 (HUD 스타일)
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
                  crossAxisAlignment: CrossAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      _speed.toStringAsFixed(1),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 26,
                        fontWeight: FontWeight.w900,
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

          // 3. 하단: 관제 문구 전용 와이드 바 (아래 배치)
          SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                width: double.infinity,
                margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.78),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _color, width: 2.2),
                  boxShadow: [
                    BoxShadow(
                      color: _color.withOpacity(0.25),
                      blurRadius: 8,
                      spreadRadius: 1,
                    )
                  ],
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      _color == Colors.greenAccent ? Icons.verified_user : Icons.warning_amber_rounded,
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
                        letterSpacing: 0.5,
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
