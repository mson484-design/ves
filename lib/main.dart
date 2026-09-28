import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:object_detection/object_detection.dart';
import 'package:permission_handler/permission_handler.dart';

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

enum VehicleMode { bus, commercial, smallVehicle }
enum RiskLevel { normal, caution, danger, emergency }

enum VideoChannel { front, rear, left, right, cabin, frontBlindSpot }

class DetectedObject {
  final String type;
  final Rect box;
  final double approachIndex;
  final bool pathConflict;
  final bool approaching;

  const DetectedObject({
    required this.type,
    required this.box,
    required this.approachIndex,
    required this.pathConflict,
    required this.approaching,
  });
}

class _TrackState {
  final String type;
  Rect box;
  DateTime lastSeen;
  double area;

  _TrackState({
    required this.type,
    required this.box,
    required this.lastSeen,
    required this.area,
  });
}

abstract class OnDeviceVision {
  Future<List<DetectedObject>> analyze(CameraImage image);
  Future<void> close();
}

/// VES 기본 비전부.
/// 핵심 원칙:
/// 1) 주변에 보인다는 이유만으로 경고하지 않는다.
/// 2) 정상 주행/정상 주차 객체는 무음이다.
/// 3) 자차 진행 통로와 관계가 있고 접근 변화가 있는 객체만 위험 후보로 본다.
/// 4) 단안 카메라의 한계를 넘어서 실제 미터 거리나 진행방향을 확정하지 않는다.
class CameraVisionAdapter implements OnDeviceVision {
  final CameraDescription camera;
  final CameraController controller;
  late final ObjectDetector _detector;

  final List<_TrackState> _tracks = <_TrackState>[];
  DateTime _lastInference = DateTime.fromMillisecondsSinceEpoch(0);
  bool _initialized = false;

  CameraVisionAdapter({required this.camera, required this.controller}) {
    _detector = ObjectDetector();
  }

  Future<void> init() async {
    await _detector.initialize(
      model: ObjectDetectionModel.efficientDetLite0,
      performanceConfig: const PerformanceConfig.auto(numThreads: 2),
    );
    _initialized = _detector.isReady;
  }

  bool get canAnalyze => _initialized && _detector.isReady;

  Rect _toRect(BoundingBox box) => Rect.fromLTRB(
        box.left,
        box.top,
        box.right,
        box.bottom,
      );

  double _iou(Rect a, Rect b) {
    final left = a.left > b.left ? a.left : b.left;
    final top = a.top > b.top ? a.top : b.top;
    final right = a.right < b.right ? a.right : b.right;
    final bottom = a.bottom < b.bottom ? a.bottom : b.bottom;
    final w = right - left;
    final h = bottom - top;
    if (w <= 0 || h <= 0) return 0;
    final intersection = w * h;
    final union = a.width * a.height + b.width * b.height - intersection;
    return union <= 0 ? 0 : intersection / union;
  }

  _TrackState? _findTrack(String type, Rect box) {
    _TrackState? best;
    var bestIou = 0.0;
    for (final track in _tracks) {
      if (track.type != type) continue;
      final iou = _iou(track.box, box);
      if (iou > bestIou) {
        bestIou = iou;
        best = track;
      }
    }
    return bestIou >= 0.12 ? best : null;
  }

  /// 실증용 '자차 진행 통로' 필터.
  /// 실제 차선검출/HD Map이 아니다. 화면 중앙 고정 사각형도 사용하지 않는다.
  bool _pathConflict(Rect box, Size imageSize) {
    if (imageSize.width <= 0 || imageSize.height <= 0) return false;

    final centerX = box.center.dx / imageSize.width;
    final bottomY = box.bottom / imageSize.height;

    // 화면 위쪽의 먼 작은 객체는 충돌 후보에서 제외한다.
    if (bottomY < 0.34) return false;

    // 아래쪽으로 갈수록 자차 진행영역이 넓어지는 단순 원근형 통로.
    final t = ((bottomY - 0.34) / 0.66).clamp(0.0, 1.0);
    final halfWidth = 0.12 + (0.23 * t);
    const pathCenter = 0.50;

    return (centerX - pathCenter).abs() <= halfWidth;
  }

  @override
  Future<List<DetectedObject>> analyze(CameraImage image) async {
    if (!canAnalyze) return const <DetectedObject>[];

    // 매 카메라 프레임마다 AI를 돌리지 않는다.
    // 0.55초 간격의 실증용 저부하 관찰이다.
    final now = DateTime.now();
    if (now.difference(_lastInference).inMilliseconds < 550) {
      return const <DetectedObject>[];
    }
    _lastInference = now;

    final rotation = rotationForFrame(
      width: image.width,
      height: image.height,
      sensorOrientation: camera.sensorOrientation,
      isFrontCamera: camera.lensDirection == CameraLensDirection.front,
      deviceOrientation: controller.value.deviceOrientation,
    );

    final detected = await _detector.detectFromCameraImage(
      image,
      rotation: rotation,
      options: const ObjectDetectorOptions(
        scoreThreshold: 0.50,
        maxResults: 6,
        categoryAllowlist: <String>[
          'person',
          'car',
          'bus',
          'truck',
          'motorcycle',
        ],
      ),
      maxDim: 480,
    );

    final results = <DetectedObject>[];

    for (final item in detected) {
      final type = _koreanType(item.categoryName);
      if (type == null || item.score < 0.50) continue;

      final box = _toRect(item.boundingBox);
      final area = box.width * box.height;
      final track = _findTrack(type, box);

      var approaching = false;
      var approachIndex = 0.0;

      if (track != null) {
        final seconds = now.difference(track.lastSeen).inMilliseconds / 1000.0;
        if (seconds > 0.05 && seconds < 2.0 && track.area > 0) {
          final growth = (area - track.area) / track.area;
          // 새로 나타난 객체가 아니라 같은 객체가 가까워지는 변화만 인정한다.
          approaching = growth > 0.08;
          approachIndex = (growth * 100).clamp(0.0, 20.0);
        }
        track.box = box;
        track.area = area;
        track.lastSeen = now;
      } else {
        final newTrack = _TrackState(
          type: type,
          box: box,
          lastSeen: now,
          area: area,
        );
        _tracks.add(newTrack);
      }

      final pathConflict = _pathConflict(box, item.originalSize);

      // 단순히 크기가 크다는 이유로 접근 차량으로 만들지 않는다.
      results.add(
        DetectedObject(
          type: type,
          box: box,
          approachIndex: approachIndex,
          pathConflict: pathConflict,
          approaching: approaching,
        ),
      );
    }

    _tracks.removeWhere(
      (track) => now.difference(track.lastSeen).inSeconds > 2,
    );

    return results;
  }

  String? _koreanType(String label) {
    if (label == 'person') return '사람';
    if ({'car', 'bus', 'truck', 'motorcycle'}.contains(label)) {
      return '차량';
    }
    return null;
  }

  @override
  Future<void> close() async {
    _tracks.clear();
    _initialized = false;
    await _detector.dispose();
  }
}

class RiskDecisionEngine {
  RiskLevel evaluate({
    required DetectedObject object,
    required double vehicleSpeed,
  }) {
    // 정차/저속 상태에서는 현재 기본 버전에서 주행 충돌 경고를 하지 않는다.
    if (vehicleSpeed < 3.0) return RiskLevel.normal;

    // 주변에 있다는 사실만으로는 위험이 아니다.
    if (!object.pathConflict) return RiskLevel.normal;

    // 정상적으로 정지/주행하는 객체는 무음이다.
    if (!object.approaching) return RiskLevel.normal;

    // 실제 m/s나 미터 단위가 아니다. 화면상 접근 변화의 실증용 지수다.
    final approach = object.approachIndex;

    // 차량 속도가 높을수록 작은 접근 변화에도 주의를 더 일찍 검토한다.
    final cautionThreshold = vehicleSpeed >= 50 ? 1.5 : 2.0;
    final dangerThreshold = vehicleSpeed >= 70 ? 4.0 : 6.0;
    final emergencyThreshold = vehicleSpeed >= 90 ? 8.0 : 12.0;

    if (approach >= emergencyThreshold) return RiskLevel.emergency;
    if (approach >= dangerThreshold) return RiskLevel.danger;
    if (approach >= cautionThreshold) return RiskLevel.caution;
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

  Future<void> dispose() async => stop();
}

class VesScreen extends StatefulWidget {
  const VesScreen({super.key});

  @override
  State<VesScreen> createState() => _VesScreenState();
}

class _VesScreenState extends State<VesScreen> with WidgetsBindingObserver {
  CameraController? _camera;
  List<CameraDescription> _cameras = const [];

  final VesVoice _voice = VesVoice();
  final RiskDecisionEngine _riskEngine = RiskDecisionEngine();
  CameraVisionAdapter? _vision;

  VehicleMode _vehicleMode = VehicleMode.bus;
  RiskLevel _riskLevel = RiskLevel.normal;

  double _speed = 0.0;
  String _status = 'VES 준비 중';
  String _subStatus = '운전자는 운전, VES는 위험 감시';

  bool _ready = false;
  bool _isAnalyzing = false;
  bool _busStopMode = false;

  Timer? _awarenessTimer;
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
          });
        }
        return;
      }

      final selected = _cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => _cameras.first,
      );

      await _camera?.dispose();
      await _vision?.close();

      final controller = CameraController(
        selected,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid
            ? ImageFormatGroup.yuv420
            : ImageFormatGroup.bgra8888,
      );

      await controller.initialize();

      final vision = CameraVisionAdapter(
        camera: selected,
        controller: controller,
      );
      await vision.init();

      if (!mounted) {
        await vision.close();
        await controller.dispose();
        return;
      }

      _camera = controller;
      _vision = vision;

      setState(() {
        _ready = true;
        _status = vision.canAnalyze ? 'VES 작동 중' : '카메라 작동 / AI 준비 필요';
        _subStatus = '운전자는 운전, VES는 위험 감시';
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

      _positionSubscription = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 1,
        ),
      ).listen((position) {
        final now = DateTime.now();
        if (now.difference(_lastSpeedUpdate).inMilliseconds < 500) return;
        _lastSpeedUpdate = now;

        final speed = position.speed.isFinite && position.speed > 0
            ? position.speed * 3.6
            : 0.0;

        if (mounted) {
          setState(() => _speed = speed);
        }
      });
    } catch (e) {
      debugPrint('Location error: $e');
    }
  }

  Future<void> _startImageAnalysis() async {
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized) return;
    if (camera.value.isStreamingImages) return;

    try {
      await camera.startImageStream((CameraImage image) async {
        if (_isAnalyzing) return;
        _isAnalyzing = true;

        try {
          final objects = await _vision?.analyze(image) ?? const <DetectedObject>[];

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
          _isAnalyzing = false;
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
    if (now.difference(_lastRiskAlert).inSeconds < 4) return;
    _lastRiskAlert = now;

    setState(() {
      _riskLevel = level;
      switch (level) {
        case RiskLevel.caution:
          _status = '주의: 위험 접근';
          _subStatus = '$objectType의 접근관계를 확인하세요';
          break;
        case RiskLevel.danger:
          _status = '위험: 충돌 가능 접근';
          _subStatus = '$objectType 접근 변화';
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
        _voice.speak('주의하세요. 차량 접근입니다.');
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
        _subStatus = _busStopMode ? '정류장 확인 모드' : '정상 안전보조';
      });
    });
  }

  void _startAwareness() {
    _awarenessTimer?.cancel();
    _awarenessTimer = Timer.periodic(const Duration(minutes: 30), (_) {
      if (_speed > 5) {
        _voice.speak(
          'VES 안전보조가 작동 중입니다.',
          minimumInterval: const Duration(minutes: 25),
        );
      }
    });
  }

  void _setBusStopMode(bool value) {
    setState(() {
      _busStopMode = value;
      _status = value ? '정류장 확인 모드' : 'VES 작동 중';
      _subStatus = value ? '승객 확인 보조' : '정상 안전보조';
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
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _modeTile(VehicleMode.bus, 'VES-BUS', '버스 / 승객안전'),
            _modeTile(VehicleMode.commercial, 'VES-COMMERCIAL', '상용차'),
            _modeTile(VehicleMode.smallVehicle, 'VES-SMALL', '승용차 / 중소형차'),
          ],
        ),
      ),
    );

    if (selected == null || !mounted) return;
    setState(() {
      _vehicleMode = selected;
      _status = 'VES 작동 중';
      _subStatus = _modeDescription(selected);
    });
  }

  Widget _modeTile(VehicleMode mode, String title, String subtitle) {
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
        return '버스 전방 위험 + 승객안전 확장';
      case VehicleMode.commercial:
        return '상용차 전방/후방 확장';
      case VehicleMode.smallVehicle:
        return '승용차 전방/후방 확장';
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
      await _camera?.dispose();
      await _vision?.close();
    } catch (_) {}

    _camera = null;
    _vision = null;
    if (mounted) setState(() => _ready = false);
  }

  Future<void> _exitVes() async {
    await _stopCameraSafely();
    await _positionSubscription?.cancel();
    _positionSubscription = null;
    await _voice.stop();
    if (mounted) await SystemNavigator.pop();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _awarenessTimer?.cancel();
    _positionSubscription?.cancel();
    _camera?.dispose();
    _vision?.close();
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
          if (_ready && _camera != null && _camera!.value.isInitialized)
            CameraPreview(_camera!)
          else
            const Center(child: CircularProgressIndicator()),

          // 의도적으로 검출 직사각형을 그리지 않는다.
          // 운전자는 화면을 볼 필요가 없고, AI가 뒤에서 관제한다.
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: Row(
                    children: [
                      _smallPill(Icons.remove_red_eye, _modeName),
                      const Spacer(),
                      _smallPill(
                        Icons.speed,
                        '${_speed.toStringAsFixed(0)} km/h',
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                if (_riskLevel != RiskLevel.normal)
                  Align(
                    alignment: Alignment.center,
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 18),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.72),
                        borderRadius: BorderRadius.circular(30),
                        border: Border.all(color: _riskColor, width: 2),
                      ),
                      child: Text(
                        _status,
                        style: TextStyle(
                          color: _riskColor,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: _smallButton(
                          icon: Icons.directions_bus,
                          text: _modeName,
                          onTap: _switchVehicleMode,
                        ),
                      ),
                      const SizedBox(width: 6),
                      if (_vehicleMode == VehicleMode.bus)
                        _iconButton(
                          Icons.person_pin_circle,
                          _busStopMode,
                          () => _setBusStopMode(!_busStopMode),
                        ),
                      const SizedBox(width: 6),
                      _iconButton(Icons.close, false, _exitVes),
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

  Widget _smallPill(IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.55),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: Colors.white70),
          const SizedBox(width: 5),
          Text(text, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }

  Widget _smallButton({
    required IconData icon,
    required String text,
    required VoidCallback onTap,
  }) {
    return ElevatedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 17),
      label: Text(text),
      style: ElevatedButton.styleFrom(
        minimumSize: const Size(0, 42),
        padding: const EdgeInsets.symmetric(horizontal: 10),
      ),
    );
  }

  Widget _iconButton(IconData icon, bool active, VoidCallback onTap) {
    return SizedBox(
      width: 48,
      height: 42,
      child: IconButton.filled(
        onPressed: onTap,
        style: IconButton.styleFrom(
          backgroundColor: active ? Colors.orange : Colors.black.withOpacity(0.65),
        ),
        icon: Icon(icon),
      ),
    );
  }
}
