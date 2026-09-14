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
  String _status = "안전 운행 중";
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
    // 1. 필수 권한
    await [Permission.camera, Permission.location].request();

    // 2. TTS 음성
    try {
      await _tts.setLanguage("ko-KR");
      await _tts.setSpeechRate(0.5);
    } catch (_) {}

    // 3. 후면 카메라 연결
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

    // 4. GPS 속도
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

    // 5. 중력이 제외된 '순수 충격/감속 센서' (userAccelerometer)
    // 폰 기울기 때문에 생기는 거짓 경보 무한 반복 원천 차단
    _sensorSub = userAccelerometerEventStream().listen((e) {
      final now = DateTime.now();
      if (now.difference(_lastCheck).inMilliseconds < 300) return;
      _lastCheck = now;

      // 경고 울린 후 8초간은 무조건 침묵 (반복 멘트 차단)
      if (now.difference(_lastAlertTime).inSeconds < 8) return;

      // 실제 급감속/충격 (가만히 있거나 기울여도 0에 가까움, 쿵 부딪혀야 12 이상 감지)
      if (e.x.abs() > 12.0 || e.y.abs() > 12.0 || e.z.abs() > 12.0) {
        _lastAlertTime = now;

        if (!mounted) return;
        setState(() {
          _status = "급감속/충격 주의!";
          _color = Colors.redAccent;
        });

        _tts.speak("주의하세요");

        _timer?.cancel();
        _timer = Timer(const Duration(seconds: 4), () {
          if (mounted) {
            setState(() {
              _status = "안전 운행 중";
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
          // 카메라 프리뷰 (화면 전체 꽉 채움)
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

          // 상단 와이드 직사각형 HUD
          SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: Container(
                width: double.infinity,
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.75),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _color, width: 2),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.shield, color: _color, size: 24),
                        const SizedBox(width: 8),
                        Text(
                          _status,
                          style: TextStyle(
                            color: _color,
                            fontSize: 19,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        Text(
                          _speed.toStringAsFixed(1),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Text(
                          'km/h',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
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
