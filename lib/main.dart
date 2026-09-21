import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';


Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const VesApp());
}

class VesApp extends StatelessWidget {
  const VesApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'VES Safety System',
      theme: ThemeData.dark(useMaterial3: true),
      home: const VesScreen(),
    );
  }
}

enum VehicleMode {
  bus,
  commercial,
  smallVehicle,
}

enum RiskLevel {
  normal,
  caution,
  danger,
  emergency,
}

enum VideoChannel {
  front,
  rear,
  left,
  right,
  cabin,
  frontBlindSpot,
}

class DetectedObject {
  final String type;
  final Rect box;
  final double relativeSpeed;
  final bool movingTowardVehicle;
  final bool inDrivingPath;
  final bool sameDirection;

  const DetectedObject({
    required this.type,
    required this.box,
    required this.relativeSpeed,
    required this.movingTowardVehicle,
    required this.inDrivingPath,
    required this.sameDirection,
  });
}

/// 실제 AI 모델이 들어올 자리.
/// 현재는 가짜 객체를 만들지 않는다.
/// 실제 온디바이스 모델을 연결하면 이 인터페이스에 결과를 넣는다.
abstract class OnDeviceVision {
  Future<List<DetectedObject>> analyze(CameraImage image);
}

/// 실증 초기 단계의 실제 카메라 입력 어댑터.
/// AI 모델이 연결되기 전까지는 빈 결과만 반환한다.
/// 즉, 화면에 보이는 풍경을 위험이라고 임의 판단하지 않는다.
class CameraVisionAdapter implements OnDeviceVision {
  @override
  Future<List<DetectedObject>> analyze(CameraImage image) async {
    return const <DetectedObject>[];
  }
}

class RiskDecisionEngine {
  RiskLevel evaluate({
    required DetectedObject object,
    required double vehicleSpeed,
  }) {
    if (!object.inDrivingPath || !object.movingTowardVehicle) {
      return RiskLevel.normal;
    }

    // 실제 상용 기준값이 아니라 AI 모델 출력값을 연결하기 위한 구조.
    // 실제 모델/실증 데이터로 검증 후 조정해야 한다.
    final v = object.relativeSpeed.abs();

    if (v >= 15) return RiskLevel.emergency;
    if (v >= 7) return RiskLevel.danger;
    if (v >= 2) return RiskLevel.caution;
    return RiskLevel.normal;
  }
}

class VesVoice {
  final FlutterTts _tts = FlutterTts();
  DateTime _lastSpeak = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> init() async {
    try {
      await _tts.setLanguage('ko-KR');
      await _tts.setSpeechRate(0.5);
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);
    } catch (_) {}
  }

  Future<void> speak(
    String text, {
    Duration minimumInterval = const Duration(seconds: 5),
  }) async {
    final now = DateTime.now();
    if (now.difference(_lastSpeak) < minimumInterval) return;

    _lastSpeak = now;

    try {
      await _tts.stop();
      await _tts.speak(text);
    } catch (_) {}
  }

  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }

  Future<void> dispose() async {
    await stop();
  }
}

class VesScreen extends StatefulWidget {
  const VesScreen({super.key});

  @override
  State<VesScreen> createState() => _VesScreenState();
}

class _VesScreenState extends State<VesScreen>
    with WidgetsBindingObserver {
  CameraController? _camera;
  List<CameraDescription> _cameras = const [];

  final VesVoice _voice = VesVoice();
  final OnDeviceVision _vision = CameraVisionAdapter();
  final RiskDecisionEngine _riskEngine = RiskDecisionEngine();

  VehicleMode _vehicleMode = VehicleMode.bus;
  RiskLevel _riskLevel = RiskLevel.normal;

  double _speed = 0.0;
  String _status = 'VES 안전보조 대기';
  String _subStatus = '실제 카메라 실증 모드';

  bool _ready = false;
  bool _isAnalyzing = false;
  bool _isRecording = false;
  bool _locationReady = false;
  bool _busStopMode = false;

  Timer? _awarenessTimer;
  Timer? _analysisTimer;

  StreamSubscription<Position>? _positionSubscription;

  DateTime _lastSpeedUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastRiskAlert = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initialize();
  }

  Future<void> _initialize() async {
    await _requestPermissions();
    await _voice.init();
    await _initializeCamera();
    await _initializeLocation();
    _startAwareness();
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.camera,
      Permission.microphone,
      Permission.location,
    ].request();
  }

  Future<void> _initializeCamera() async {
    try {
      _cameras = await availableCameras();

      if (_cameras.isEmpty) {
        if (mounted) {
          setState(() {
            _status = '카메라를 찾을 수 없습니다';
            _subStatus = '카메라 연결을 확인하세요';
          });
        }
        return;
      }

      final selected = _cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => _cameras.first,
      );

      await _camera?.dispose();

      final controller = CameraController(
        selected,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid
            ? ImageFormatGroup.yuv420
            : ImageFormatGroup.bgra8888,
      );

      await controller.initialize();

      if (!mounted) {
        await controller.dispose();
        return;
      }

      _camera = controller;

      setState(() {
        _ready = true;
        _status = 'VES 작동 중';
        _subStatus = '전방 카메라 실증 준비 완료';
      });

      _startImageAnalysis();
    } catch (e) {
      debugPrint('Camera initialization error: $e');

      if (mounted) {
        setState(() {
          _status = '카메라 초기화 오류';
          _subStatus = e.toString();
        });
      }
    }
  }

  Future<void> _initializeLocation() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return;

      var permission = await Geolocator.checkPermission();

      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return;
      }

      _locationReady = true;

      _positionSubscription =
          Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 1,
        ),
      ).listen((position) {
        final now = DateTime.now();

        if (now.difference(_lastSpeedUpdate).inMilliseconds < 500) {
          return;
        }

        _lastSpeedUpdate = now;

        final speed = position.speed.isFinite && position.speed > 0
            ? position.speed * 3.6
            : 0.0;

        if (mounted) {
          setState(() {
            _speed = speed;
          });
        }
      });
    } catch (e) {
      debugPrint('Location error: $e');
    }
  }

  void _startImageAnalysis() {
    _analysisTimer?.cancel();

    // 실제 카메라 프레임을 받는다.
    // 가짜 객체를 생성하지 않는다.
    _analysisTimer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => _analyzeCurrentCamera(),
    );
  }

  Future<void> _analyzeCurrentCamera() async {
    if (!_ready ||
        _camera == null ||
        !_camera!.value.isInitialized ||
        _isAnalyzing) {
      return;
    }

    if (_camera!.value.isStreamingImages) return;

    _isAnalyzing = true;

    try {
      await _camera!.startImageStream((CameraImage image) async {
        if (!_isAnalyzing) return;

        _isAnalyzing = false;

        try {
          final objects = await _vision.analyze(image);

          for (final object in objects) {
            final level = _riskEngine.evaluate(
              object: object,
              vehicleSpeed: _speed,
            );

            if (level.index > _riskLevel.index) {
              _applyRisk(level, object.type);
            }
          }
        } catch (e) {
          debugPrint('Vision analysis error: $e');
        } finally {
          if (_camera?.value.isStreamingImages == true) {
            try {
              await _camera?.stopImageStream();
            } catch (_) {}
          }
        }
      });
    } catch (e) {
      _isAnalyzing = false;
      debugPrint('Image stream error: $e');
    }
  }

  void _applyRisk(RiskLevel level, String objectType) {
    if (!mounted) return;

    final now = DateTime.now();

    if (now.difference(_lastRiskAlert).inSeconds < 4) {
      return;
    }

    _lastRiskAlert = now;

    setState(() {
      _riskLevel = level;

      switch (level) {
        case RiskLevel.caution:
          _status = '주의: 위험 접근 감지';
          _subStatus = '$objectType 접근 관계 확인';
          break;
        case RiskLevel.danger:
          _status = '위험: 위험 접근';
          _subStatus = '$objectType 충돌 가능성 증가';
          break;
        case RiskLevel.emergency:
          _status = '긴급: 충돌 위험';
          _subStatus = '$objectType 즉시 주의';
          break;
        case RiskLevel.normal:
          _status = 'VES 작동 중';
          _subStatus = '정상 안전보조';
          break;
      }
    });

    switch (level) {
      case RiskLevel.caution:
        _voice.speak('주의하세요. 접근 중입니다.');
        break;
      case RiskLevel.danger:
        _voice.speak('위험 접근입니다.');
        break;
      case RiskLevel.emergency:
        _voice.speak(
          '충돌 위험입니다.',
          minimumInterval: const Duration(seconds: 2),
        );
        break;
      case RiskLevel.normal:
        break;
    }

    Timer(const Duration(seconds: 4), () {
      if (!mounted) return;

      setState(() {
        _riskLevel = RiskLevel.normal;
        _status = 'VES 작동 중';
        _subStatus = _busStopMode
            ? '정류장 승객 확인 모드'
            : '정상 안전보조';
      });
    });
  }

  void _startAwareness() {
    _awarenessTimer?.cancel();

    // 장시간 운전 중 운전자 각성을 위한 짧은 상태 안내.
    // 과도한 반복 음성을 피한다.
    _awarenessTimer = Timer.periodic(
      const Duration(minutes: 30),
      (_) {
        if (_speed > 5) {
          _voice.speak(
            'VES 안전보조가 작동 중입니다.',
            minimumInterval: const Duration(minutes: 25),
          );
        }
      },
    );
  }

  Future<void> _toggleRecording() async {
    final camera = _camera;

    if (camera == null || !camera.value.isInitialized) return;

    try {
      if (camera.value.isRecordingVideo) {
        final file = await camera.stopVideoRecording();

        if (mounted) {
          setState(() {
            _isRecording = false;
            _status = 'VES 작동 중';
            _subStatus = '영상 저장 완료: ${file.path}';
          });
        }

        await _voice.speak(
          '실증 영상 저장이 완료되었습니다.',
          minimumInterval: const Duration(seconds: 10),
        );
        return;
      }

      final directory = await _getRecordingDirectory();

      // camera 플러그인이 실제 파일을 관리하도록 하고,
      // 앱 종료 전까지 저장 경로를 기록한다.
      await camera.startVideoRecording();

      if (mounted) {
        setState(() {
          _isRecording = true;
          _status = 'VES 실증 촬영 중';
          _subStatus = directory.path;
        });
      }
    } catch (e) {
      debugPrint('Recording error: $e');

      if (mounted) {
        setState(() {
          _isRecording = false;
          _status = '촬영 오류';
          _subStatus = e.toString();
        });
      }
    }
  }

  Future<Directory> _getRecordingDirectory() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/VES_Recordings');

    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    return dir;
  }

  void _setBusStopMode(bool value) {
    setState(() {
      _busStopMode = value;
      _status = value ? '정류장 승객 확인 모드' : 'VES 작동 중';
      _subStatus = value
          ? '실제 정류장 상황을 카메라로 확인'
          : '정상 안전보조';
    });

    if (value) {
      _voice.speak(
        '정류장입니다. 승객을 확인하세요.',
        minimumInterval: const Duration(seconds: 10),
      );
    }
  }

  Future<void> _switchVehicleMode() async {
    final selected = await showModalBottomSheet<VehicleMode>(
      context: context,
      backgroundColor: Colors.black87,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _modeTile(VehicleMode.bus, 'VES-BUS', '버스 / 승객안전'),
              _modeTile(
                VehicleMode.commercial,
                'VES-COMMERCIAL',
                '상용차',
              ),
              _modeTile(
                VehicleMode.smallVehicle,
                'VES-SMALL',
                '중소형차 / 승용차',
              ),
            ],
          ),
        );
      },
    );

    if (selected == null || !mounted) return;

    setState(() {
      _vehicleMode = selected;
      _status = 'VES 작동 중';
      _subStatus = _modeDescription(selected);
    });
  }

  Widget _modeTile(
    VehicleMode mode,
    String title,
    String subtitle,
  ) {
    return ListTile(
      leading: const Icon(Icons.directions_car),
      title: Text(title),
      subtitle: Text(subtitle),
      onTap: () => Navigator.pop(context, mode),
    );
  }

  String _modeDescription(VehicleMode mode) {
    switch (mode) {
      case VehicleMode.bus:
        return '전방/후방/좌우/차내 입력 확장 + 승객안전';
      case VehicleMode.commercial:
        return '전방/후방/전면 사각 입력 확장';
      case VehicleMode.smallVehicle:
        return '전방/후방 블랙박스 입력 확장';
    }
  }

  Color get _riskColor {
    switch (_riskLevel) {
      case RiskLevel.normal:
        return Colors.greenAccent;
      case RiskLevel.caution:
        return Colors.amberAccent;
      case RiskLevel.danger:
        return Colors.orangeAccent;
      case RiskLevel.emergency:
        return Colors.redAccent;
    }
  }

  IconData get _riskIcon {
    switch (_riskLevel) {
      case RiskLevel.normal:
        return Icons.shield;
      case RiskLevel.caution:
        return Icons.warning_amber_rounded;
      case RiskLevel.danger:
      case RiskLevel.emergency:
        return Icons.warning_rounded;
    }
  }

  String get _modeName {
    switch (_vehicleMode) {
      case VehicleMode.bus:
        return 'VES-BUS';
      case VehicleMode.commercial:
        return 'VES-COMMERCIAL';
      case VehicleMode.smallVehicle:
        return 'VES-SMALL';
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _stopCameraSafely();
    } else if (state == AppLifecycleState.resumed) {
      _initializeCamera();
    }
  }

  Future<void> _stopCameraSafely() async {
    try {
      if (_camera?.value.isStreamingImages == true) {
        await _camera?.stopImageStream();
      }

      if (_camera?.value.isRecordingVideo == true) {
        // 백그라운드에서 강제로 녹화를 유지하지 않는다.
        await _camera?.stopVideoRecording();
      }

      await _camera?.dispose();
    } catch (_) {}

    _camera = null;

    if (mounted) {
      setState(() {
        _ready = false;
        _isRecording = false;
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);

    _awarenessTimer?.cancel();
    _analysisTimer?.cancel();
    _positionSubscription?.cancel();

    _camera?.dispose();
    _voice.dispose();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (_ready &&
              _camera != null &&
              _camera!.value.isInitialized)
            CameraPreview(_camera!)
          else
            const Center(
              child: CircularProgressIndicator(
                color: Colors.greenAccent,
              ),
            ),

          SafeArea(
            child: Column(
              children: [
                Row(
                  children: [
                    _topButton(
                      icon: Icons.directions_bus,
                      text: _modeName,
                      onTap: _switchVehicleMode,
                    ),
                    const Spacer(),
                    Container(
                      margin: const EdgeInsets.only(
                        top: 10,
                        right: 10,
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.7),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          Text(
                            _speed.toStringAsFixed(1),
                            style: const TextStyle(
                              fontSize: 25,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(width: 5),
                          const Text('km/h'),
                        ],
                      ),
                    ),
                  ],
                ),

                const Spacer(),

                if (_vehicleMode == VehicleMode.bus)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                    ),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: FloatingActionButton.small(
                        heroTag: 'busStop',
                        onPressed: () =>
                            _setBusStopMode(!_busStopMode),
                        backgroundColor:
                            _busStopMode ? Colors.orange : Colors.black87,
                        child: const Icon(Icons.person_pin_circle),
                      ),
                    ),
                  ),

                const SizedBox(height: 8),

                Container(
                  margin: const EdgeInsets.all(14),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.82),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: _riskColor,
                      width: 2,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _riskIcon,
                        color: _riskColor,
                        size: 30,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment.start,
                          children: [
                            Text(
                              _status,
                              style: TextStyle(
                                color: _riskColor,
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _subStatus,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                Padding(
                  padding: const EdgeInsets.only(
                    left: 14,
                    right: 14,
                    bottom: 14,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _toggleRecording,
                          icon: Icon(
                            _isRecording
                                ? Icons.stop
                                : Icons.fiber_manual_record,
                          ),
                          label: Text(
                            _isRecording ? '촬영 중지' : '실증 촬영',
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _topButton({
    required IconData icon,
    required String text,
    required VoidCallback onTap,
  }) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(left: 10, top: 10),
        child: ElevatedButton.icon(
          onPressed: onTap,
          icon: Icon(icon, size: 18),
          label: Text(text),
        ),
      ),
    );
  }
}
