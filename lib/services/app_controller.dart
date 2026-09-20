import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/camera.dart';
import 'discovery.dart';
import 'onvif_ptz.dart';

/// Estado do app: cadastro das cameras, senhas e resolucao de MAC para IP.
///
/// O cadastro fica em SharedPreferences. As senhas ficam separadas, no
/// armazenamento seguro do Android, cifradas pelo Keystore do aparelho.
class AppController extends ChangeNotifier {
  static const _kCameras = 'cameras';
  static const _kGridMain = 'grid_main_stream';
  static const Duration scanInterval = Duration(seconds: 30);

  final FlutterSecureStorage _secure = const FlutterSecureStorage();
  late final SharedPreferences _prefs;

  List<Camera> _cameras = [];
  final Map<String, String> _passwords = {};
  Set<String> _online = {};

  /// Varreduras seguidas sem resposta, por MAC. Broadcast em Wi-Fi perde pacotes,
  /// entao uma unica falha nao marca a camera como fora da rede.
  final Map<String, int> _misses = {};
  Timer? _timer;
  Future<void>? _scanning;

  bool loaded = false;
  bool gridMainStream = false;
  DateTime? lastScan;

  List<Camera> get cameras => List.unmodifiable(_cameras);
  bool get isScanning => _scanning != null;
  bool isOnline(Camera c) => _online.contains(c.mac);
  bool hasPassword(Camera c) => (_passwords[c.id] ?? '').isNotEmpty;

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    gridMainStream = _prefs.getBool(_kGridMain) ?? false;
    try {
      final raw = jsonDecode(_prefs.getString(_kCameras) ?? '[]');
      if (raw is List) {
        _cameras = raw.map(Camera.fromJson).whereType<Camera>().toList();
      }
    } catch (_) {
      _cameras = [];
    }
    for (final c in _cameras) {
      try {
        _passwords[c.id] = await _secure.read(key: _pwKey(c.id)) ?? '';
      } catch (_) {
        _passwords[c.id] = '';
      }
    }
    loaded = true;
    notifyListeners();
    start();
  }

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(scanInterval, (_) => rescan());
    rescan();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// URL pronta para o player, ou null enquanto o IP nao for conhecido.
  String? urlFor(Camera c, {required bool mainStream}) {
    if (c.lastIp.isEmpty) return null;
    return c.buildUrl(ip: c.lastIp, password: _passwords[c.id] ?? '', mainStream: mainStream);
  }

  /// Cliente de movimento da camera, ou null enquanto o IP nao for conhecido.
  /// A senha fica encapsulada aqui e nao passa pela interface.
  OnvifPtz? ptzFor(Camera c) {
    if (c.lastIp.isEmpty) return null;
    return OnvifPtz(
      ip: c.lastIp,
      user: c.user,
      password: _passwords[c.id] ?? '',
      invertPan: c.invertPan,
      invertTilt: c.invertTilt,
    );
  }

  /// Procura as cameras cadastradas na rede e atualiza os IPs que mudaram.
  Future<void> rescan() {
    return _scanning ??= _rescan().whenComplete(() {
      _scanning = null;
      notifyListeners();
    });
  }

  Future<void> _rescan() async {
    if (_cameras.isEmpty) {
      _online = {};
      return;
    }
    notifyListeners();
    final found = await XmDiscovery.discover(knownIps: _cameras.map((c) => c.lastIp));
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    var ipChanged = false;
    final updated = <Camera>[];
    final online = <String>{};
    for (var c in _cameras) {
      // Cadastros antigos nao tem o numero de serie. Quando o MAC responde, o app
      // completa sozinho, e a camera passa a ser acompanhada pelas duas interfaces.
      if (c.serial.isEmpty) {
        for (final d in found) {
          if (d.mac == c.mac && d.serial.isNotEmpty) {
            c = c.copyWith(serial: d.serial);
            ipChanged = true; // forca a gravacao do cadastro
            break;
          }
        }
      }
      final misses = _misses[c.mac] ?? 0;
      final ip = pickIp(mac: c.mac, serial: c.serial, lastIp: c.lastIp, misses: misses, found: found);
      if (ip == null) {
        _misses[c.mac] = misses + 1;
        // Uma unica varredura sem resposta nao marca a camera como fora da rede.
        if (misses + 1 < 2 && c.lastIp.isNotEmpty) online.add(c.mac);
        updated.add(c);
        continue;
      }
      _misses[c.mac] = 0;
      online.add(c.mac);
      if (ip != c.lastIp) {
        ipChanged = true;
        debugPrint('[camwall] ${c.name} (${c.mac}): IP ${c.lastIp.isEmpty ? "desconhecido" : c.lastIp} -> $ip');
      }
      updated.add(c.copyWith(lastIp: ip, lastSeen: now));
    }
    _cameras = updated;
    _misses.removeWhere((mac, _) => !_cameras.any((c) => c.mac == mac));
    _online = online;
    lastScan = DateTime.now();
    if (ipChanged) await _saveCameras();
  }

  /// Procura todas as cameras da rede, uma entrada por aparelho.
  Future<List<FoundCamera>> discoverAll() async {
    return groupBySerial(await XmDiscovery.discover(knownIps: _cameras.map((c) => c.lastIp)));
  }

  /// A camera ja cadastrada que corresponde a um aparelho encontrado, se houver.
  Camera? registeredFor(FoundCamera f) {
    for (final c in _cameras) {
      if (f.macs.contains(c.mac) || (c.serial.isNotEmpty && c.serial == f.serial)) return c;
    }
    return null;
  }

  String? validate({required String name, required String mac, String? ignoreId}) {
    if (name.trim().isEmpty || name.trim().length > 60) {
      return 'Informe um nome com até 60 caracteres.';
    }
    final m = normalizeMac(mac);
    if (m == null) return 'MAC inválido. Exemplo: 02:1a:2b:ce:41:f5';
    if (_cameras.any((c) => c.mac == m && c.id != ignoreId)) {
      return 'Já existe uma câmera com esse MAC.';
    }
    return null;
  }

  /// Cria ou atualiza. `password == null` mantem a senha atual.
  Future<void> save({
    String? id,
    required String name,
    required String mac,
    required String user,
    required String template,
    String? password,
    String knownIp = '',
    String? serial,
    bool? invertPan,
    bool? invertTilt,
  }) async {
    final m = normalizeMac(mac)!;
    final tpl = template.trim().isEmpty ? kDefaultTemplate : template.trim();
    final index = id == null ? -1 : _cameras.indexWhere((c) => c.id == id);
    Camera cam;
    if (index >= 0) {
      final old = _cameras[index];
      final macChanged = old.mac != m;
      cam = old.copyWith(
        name: name.trim(),
        mac: m,
        user: user.trim(),
        template: tpl,
        serial: macChanged ? (serial ?? '') : serial,
        invertPan: invertPan,
        invertTilt: invertTilt,
        lastIp: macChanged ? knownIp : null,
        lastSeen: macChanged ? 0 : null,
      );
      _cameras = [..._cameras]..[index] = cam;
    } else {
      cam = Camera(
        id: Camera.newId(),
        name: name.trim(),
        mac: m,
        user: user.trim(),
        template: tpl,
        serial: serial ?? '',
        invertPan: invertPan ?? true,
        invertTilt: invertTilt ?? false,
        lastIp: knownIp,
      );
      _cameras = [..._cameras, cam];
    }
    if (password != null) {
      _passwords[cam.id] = password;
      if (password.isEmpty) {
        await _secure.delete(key: _pwKey(cam.id));
      } else {
        await _secure.write(key: _pwKey(cam.id), value: password);
      }
    } else {
      _passwords.putIfAbsent(cam.id, () => '');
    }
    await _saveCameras();
    notifyListeners();
    unawaited(rescan());
  }

  Future<void> remove(String id) async {
    _cameras = _cameras.where((c) => c.id != id).toList();
    _passwords.remove(id);
    try {
      await _secure.delete(key: _pwKey(id));
    } catch (_) {}
    await _saveCameras();
    notifyListeners();
  }

  Future<void> setGridMainStream(bool value) async {
    gridMainStream = value;
    await _prefs.setBool(_kGridMain, value);
    notifyListeners();
  }

  Future<void> _saveCameras() => _prefs.setString(_kCameras, jsonEncode(_cameras.map((c) => c.toJson()).toList()));

  static String _pwKey(String id) => 'camera_password_$id';

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
