import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:android_id/android_id.dart';
import 'package:camera/camera.dart';
import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:saver_gallery/saver_gallery.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const CheckInApp());
}

class CheckInApp extends StatelessWidget {
  const CheckInApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '现场打卡',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      fontFamily: 'sans',
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff0c7167)),
    ),
    home: const CheckInPage(),
  );
}

class CheckInPage extends StatefulWidget {
  const CheckInPage({super.key});

  @override
  State<CheckInPage> createState() => _CheckInPageState();
}

class _CheckInPageState extends State<CheckInPage> {
  static const _teal = Color(0xff0b7168);
  static const _ink = Color(0xff132322);
  final _evidenceKey = GlobalKey();
  final _random = Random.secure();
  List<CameraDescription> _cameras = [];
  CameraController? _camera;
  Position? _position;
  String? _deviceCode;
  String? _setupError;
  bool _loading = true;
  bool _locating = false;
  bool _taking = false;
  bool _switchingCamera = false;
  File? _photo;
  CheckInReceipt? _receipt;
  String? _savedPath;
  bool _savedToGallery = false;
  String? _galleryError;

  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    try {
      await Future.wait([
        _startCamera(),
        _refreshLocation(),
        _loadDeviceCode(),
      ]);
    } catch (error) {
      _setupError = '无法启动打卡：$error';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _startCamera() async {
    _cameras = await availableCameras();
    if (_cameras.isEmpty) throw StateError('未发现可用相机');
    final preferred = _cameras.firstWhere(
      (camera) => camera.lensDirection == CameraLensDirection.back,
      orElse: () => _cameras.first,
    );
    await _activateCamera(preferred);
  }

  Future<void> _activateCamera(CameraDescription description) async {
    final controller = CameraController(
      description,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    await controller.initialize();
    if (!mounted) {
      await controller.dispose();
      return;
    }
    _camera = controller;
  }

  Future<void> _switchCamera() async {
    if (_cameras.length < 2 || _camera == null || _switchingCamera) return;
    final currentDirection = _camera!.description.lensDirection;
    final wantedDirection = currentDirection == CameraLensDirection.front
        ? CameraLensDirection.back
        : CameraLensDirection.front;
    final next = _cameras.firstWhere(
      (camera) => camera.lensDirection == wantedDirection,
      orElse: () => _cameras.firstWhere(
        (camera) => camera.name != _camera!.description.name,
        orElse: () => _camera!.description,
      ),
    );
    if (next.name == _camera!.description.name) return;

    setState(() => _switchingCamera = true);
    final previous = _camera;
    _camera = null;
    try {
      await previous?.dispose();
      await _activateCamera(next);
      if (mounted) setState(() {});
    } on CameraException catch (error) {
      _showMessage('切换摄像头失败：${error.description ?? error.code}');
    } finally {
      if (mounted) setState(() => _switchingCamera = false);
    }
  }

  Future<void> _refreshLocation() async {
    if (mounted) setState(() => _locating = true);
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        throw StateError('请先开启系统定位服务');
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw StateError('需要位置权限才能生成打卡凭证');
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
          timeLimit: Duration(seconds: 15),
        ),
      );
      if (mounted) setState(() => _position = position);
    } catch (error) {
      if (mounted) setState(() => _setupError = '$error');
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _loadDeviceCode() async {
    final plugin = DeviceInfoPlugin();
    String raw;
    if (Platform.isAndroid) {
      final info = await plugin.androidInfo;
      final androidId = await const AndroidId().getId();
      raw = '$androidId|${info.brand}|${info.model}|${info.device}';
    } else if (Platform.isIOS) {
      final info = await plugin.iosInfo;
      raw = '${info.name}|${info.model}|${info.identifierForVendor}';
    } else {
      raw = '${Platform.operatingSystem}|${Platform.localHostname}';
    }
    _deviceCode = sha256
        .convert(utf8.encode(raw))
        .toString()
        .substring(0, 16)
        .toUpperCase();
  }

  Future<void> _takeCheckInPhoto() async {
    if (_camera == null || _deviceCode == null || _taking) return;
    setState(() {
      _taking = true;
      // A failed refresh must never fall back to a previously cached location.
      _position = null;
    });
    try {
      await _refreshLocation();
      final position = _position;
      if (position == null) throw StateError('没有获取到有效定位，请重试');
      if (position.accuracy > 100) {
        throw StateError(
          '当前位置精度为 ${position.accuracy.toStringAsFixed(0)} 米，请到开阔处重试',
        );
      }
      final xFile = await _camera!.takePicture();
      final photo = File(xFile.path);
      if (!mounted) return;
      await precacheImage(FileImage(photo), context);
      final capturedAt = DateTime.now();
      final receipt = CheckInReceipt(
        capturedAt: capturedAt,
        latitude: position.latitude,
        longitude: position.longitude,
        accuracy: position.accuracy,
        deviceCode: _deviceCode!,
        nonce: _nonce(),
      );
      if (!mounted) return;
      setState(() {
        _photo = photo;
        _receipt = receipt;
        _savedPath = null;
        _savedToGallery = false;
        _galleryError = null;
      });
      await _saveStampedEvidence();
    } on CameraException catch (error) {
      _showMessage('相机拍摄失败：${error.description ?? error.code}');
    } catch (error) {
      _showMessage('$error');
    } finally {
      if (mounted) setState(() => _taking = false);
    }
  }

  String _nonce() => base64UrlEncode(
    List<int>.generate(8, (_) => _random.nextInt(256)),
  ).replaceAll('=', '');

  Future<void> _saveStampedEvidence() async {
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final context = _evidenceKey.currentContext;
    final boundary = context?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) throw StateError('凭证渲染失败，请重新拍摄');
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) throw StateError('凭证导出失败');
    final root = await getApplicationDocumentsDirectory();
    final folder = Directory('${root.path}/checkin_evidence');
    await folder.create(recursive: true);
    final target = File('${folder.path}/checkin_${_receipt!.fileStamp}.png');
    final bytes = data.buffer.asUint8List();
    await target.writeAsBytes(bytes, flush: true);
    final galleryResult = await SaverGallery.saveImage(
      bytes,
      fileName: '现场打卡_${_receipt!.fileStamp}.png',
      androidRelativePath: 'Pictures/现场打卡',
      skipIfExists: false,
    );
    if (mounted) {
      setState(() {
        _savedPath = target.path;
        _savedToGallery = galleryResult.isSuccess;
        _galleryError = galleryResult.errorMessage;
      });
    }
  }

  void _retake() => setState(() {
    _photo = null;
    _receipt = null;
    _savedPath = null;
    _savedToGallery = false;
    _galleryError = null;
  });

  void _showMessage(String message) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  void dispose() {
    _camera?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasEvidence = _photo != null && _receipt != null;
    return Scaffold(
      backgroundColor: const Color(0xfff5f7f4),
      body: SafeArea(
        child: Column(
          children: [
            _Header(deviceCode: _deviceCode),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 260),
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : hasEvidence
                    ? _evidenceScreen()
                    : _cameraScreen(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _cameraScreen() {
    if (_camera == null) return _setupProblem();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      child: Column(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CameraPreview(_camera!),
                  const _CameraGuide(),
                  Positioned(
                    top: 18,
                    left: 18,
                    right: 18,
                    child: _LiveBadge(position: _position, loading: _locating),
                  ),
                  Positioned(
                    top: 76,
                    right: 18,
                    child: _CameraSwitchButton(
                      enabled:
                          _cameras.length > 1 && !_taking && !_switchingCamera,
                      switching: _switchingCamera,
                      onPressed: _switchCamera,
                    ),
                  ),
                  const Positioned(
                    left: 18,
                    right: 18,
                    bottom: 18,
                    child: Text(
                      '仅支持调用系统相机现场拍摄',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        shadows: [Shadow(blurRadius: 8)],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
          _securityStrip(),
          const SizedBox(height: 17),
          SizedBox(
            width: double.infinity,
            height: 58,
            child: FilledButton.icon(
              onPressed: _taking ? null : _takeCheckInPhoto,
              icon: _taking
                  ? const SizedBox(
                      width: 21,
                      height: 21,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.camera_alt_rounded),
              label: Text(_taking ? '正在生成可信凭证…' : '拍摄并完成打卡'),
              style: FilledButton.styleFrom(
                backgroundColor: _teal,
                foregroundColor: Colors.white,
                textStyle: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _setupProblem() => Padding(
    padding: const EdgeInsets.all(28),
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.no_photography_rounded, size: 48, color: _teal),
          const SizedBox(height: 16),
          const Text(
            '需要相机和定位权限',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(
            _setupError ?? '正在检查设备权限',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.black54),
          ),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: _prepare,
            icon: const Icon(Icons.refresh),
            label: const Text('重新检查'),
          ),
        ],
      ),
    ),
  );

  Widget _securityStrip() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
    decoration: BoxDecoration(
      color: const Color(0xffe7f3ef),
      borderRadius: BorderRadius.circular(14),
    ),
    child: const Row(
      children: [
        Icon(Icons.verified_user_rounded, color: _teal, size: 19),
        SizedBox(width: 9),
        Expanded(
          child: Text(
            '现场照片将写入时间、定位、设备码与防篡改凭证',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: _ink,
            ),
          ),
        ),
      ],
    ),
  );

  Widget _evidenceScreen() {
    final receipt = _receipt!;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          RepaintBoundary(
            key: _evidenceKey,
            child: _EvidenceCanvas(photo: _photo!, receipt: receipt),
          ),
          const SizedBox(height: 16),
          if (_savedPath == null)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(8),
                child: Text('正在固化水印凭证…'),
              ),
            )
          else
            _SuccessCard(
              filePath: _savedPath!,
              savedToGallery: _savedToGallery,
              galleryError: _galleryError,
            ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _retake,
            icon: const Icon(Icons.camera_alt_outlined),
            label: const Text('重新现场拍摄'),
            style: OutlinedButton.styleFrom(
              foregroundColor: _teal,
              minimumSize: const Size.fromHeight(52),
            ),
          ),
        ],
      ),
    );
  }
}

class CheckInReceipt {
  CheckInReceipt({
    required this.capturedAt,
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    required this.deviceCode,
    required this.nonce,
  });
  final DateTime capturedAt;
  final double latitude;
  final double longitude;
  final double accuracy;
  final String deviceCode;
  final String nonce;
  String get timestamp =>
      '${capturedAt.year}-${_two(capturedAt.month)}-${_two(capturedAt.day)} ${_two(capturedAt.hour)}:${_two(capturedAt.minute)}:${_two(capturedAt.second)}';
  String get coordinate =>
      '${latitude.toStringAsFixed(6)}, ${longitude.toStringAsFixed(6)}';
  String get fileStamp =>
      '${capturedAt.year}${_two(capturedAt.month)}${_two(capturedAt.day)}_${_two(capturedAt.hour)}${_two(capturedAt.minute)}${_two(capturedAt.second)}';
  String get qrData => jsonEncode({
    'v': 1,
    'type': 'on_site_checkin',
    'time': capturedAt.toUtc().toIso8601String(),
    'gps': {
      'lat': latitude,
      'lng': longitude,
      'accuracy_m': accuracy.toStringAsFixed(1),
    },
    'device': deviceCode,
    'nonce': nonce,
  });
  static String _two(int value) => value.toString().padLeft(2, '0');
}

class _Header extends StatelessWidget {
  const _Header({this.deviceCode});
  final String? deviceCode;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(22, 15, 22, 12),
    child: Row(
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: const Color(0xffd8f0ea),
            borderRadius: BorderRadius.circular(14),
          ),
          child: const Icon(Icons.shield_rounded, color: Color(0xff0b7168)),
        ),
        const SizedBox(width: 11),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '现场打卡',
                style: TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w900,
                  color: Color(0xff132322),
                ),
              ),
              Text(
                '可信影像凭证',
                style: TextStyle(fontSize: 12, color: Color(0xff61716e)),
              ),
            ],
          ),
        ),
        if (deviceCode != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0xffd7e1de)),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '设备 ${deviceCode!.substring(0, 6)}',
              style: const TextStyle(
                fontSize: 10,
                color: Color(0xff54615f),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
      ],
    ),
  );
}

class _LiveBadge extends StatelessWidget {
  const _LiveBadge({required this.position, required this.loading});
  final Position? position;
  final bool loading;
  @override
  Widget build(BuildContext context) {
    final ready = position != null;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .58),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(
            ready ? Icons.gps_fixed_rounded : Icons.gps_not_fixed_rounded,
            color: ready ? const Color(0xff7df0c9) : const Color(0xffffd46e),
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              loading
                  ? '正在校验实时定位…'
                  : ready
                  ? '定位精度 ${position!.accuracy.toStringAsFixed(0)} 米 · 已锁定'
                  : '尚未获得定位',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CameraGuide extends StatelessWidget {
  const _CameraGuide();
  @override
  Widget build(BuildContext context) => Center(
    child: Container(
      width: 220,
      height: 280,
      decoration: BoxDecoration(
        border: Border.all(
          color: Colors.white.withValues(alpha: .68),
          width: 1.6,
        ),
        borderRadius: BorderRadius.circular(20),
      ),
    ),
  );
}

class _CameraSwitchButton extends StatelessWidget {
  const _CameraSwitchButton({
    required this.enabled,
    required this.switching,
    required this.onPressed,
  });

  final bool enabled;
  final bool switching;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.black.withValues(alpha: .58),
    shape: const CircleBorder(),
    child: IconButton(
      tooltip: '切换前后摄像头',
      onPressed: enabled ? onPressed : null,
      icon: switching
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : const Icon(Icons.cameraswitch_rounded, color: Colors.white),
    ),
  );
}

class _EvidenceCanvas extends StatelessWidget {
  const _EvidenceCanvas({required this.photo, required this.receipt});
  final File photo;
  final CheckInReceipt receipt;
  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(25),
    child: AspectRatio(
      aspectRatio: 3 / 4,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.file(photo, fit: BoxFit.cover),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0x88000000),
                  Colors.transparent,
                  Color(0xaa000000),
                ],
                stops: [0, .35, 1],
              ),
            ),
          ),
          Positioned(
            top: 18,
            left: 18,
            right: 18,
            child: Row(
              children: [
                Container(
                  width: 9,
                  height: 9,
                  decoration: const BoxDecoration(
                    color: Color(0xffffcf55),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 7),
                const Text(
                  '现场拍摄 · 不可从相册导入',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: _WatermarkPanel(receipt: receipt),
          ),
        ],
      ),
    ),
  );
}

class _WatermarkPanel extends StatelessWidget {
  const _WatermarkPanel({required this.receipt});
  final CheckInReceipt receipt;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(11),
    decoration: BoxDecoration(
      color: const Color(0xef081515),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: Colors.white.withValues(alpha: .25)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'CHECK-IN EVIDENCE',
                style: TextStyle(
                  fontSize: 9,
                  letterSpacing: 1.2,
                  color: Color(0xff8ef1d0),
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                receipt.timestamp,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'GPS  ${receipt.coordinate}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                '精度 ±${receipt.accuracy.toStringAsFixed(0)}m  ·  设备 ${receipt.deviceCode}',
                style: const TextStyle(color: Color(0xffc5d1cf), fontSize: 9.5),
              ),
              const SizedBox(height: 3),
              Text(
                '凭证 ${receipt.nonce}',
                style: const TextStyle(color: Color(0xffc5d1cf), fontSize: 9.5),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Container(
          color: Colors.white,
          padding: const EdgeInsets.all(4),
          child: QrImageView(
            data: receipt.qrData,
            version: QrVersions.auto,
            size: 76,
            eyeStyle: const QrEyeStyle(
              eyeShape: QrEyeShape.square,
              color: Color(0xff111111),
            ),
            dataModuleStyle: const QrDataModuleStyle(
              dataModuleShape: QrDataModuleShape.square,
              color: Color(0xff111111),
            ),
          ),
        ),
      ],
    ),
  );
}

class _SuccessCard extends StatelessWidget {
  const _SuccessCard({
    required this.filePath,
    required this.savedToGallery,
    this.galleryError,
  });
  final String filePath;
  final bool savedToGallery;
  final String? galleryError;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(15),
    decoration: BoxDecoration(
      color: const Color(0xffe6f5ee),
      borderRadius: BorderRadius.circular(17),
    ),
    child: Row(
      children: [
        Icon(
          savedToGallery
              ? Icons.photo_library_rounded
              : Icons.warning_amber_rounded,
          color: savedToGallery
              ? const Color(0xff087a61)
              : const Color(0xffa56000),
          size: 26,
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                savedToGallery ? '已保存到系统相册' : '打卡凭证已生成',
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  color: Color(0xff145143),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                savedToGallery ? '水印与二维码已写入相册照片' : '相册保存失败，请检查相册权限后重试',
                style: const TextStyle(fontSize: 12, color: Color(0xff367164)),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
