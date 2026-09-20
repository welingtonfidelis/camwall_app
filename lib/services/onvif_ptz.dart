// Controle de movimento (PTZ) pelo ONVIF, o padrao aberto de cameras IP.
//
// O comando sai direto do aparelho para a camera, por HTTP na rede local.
// Dart puro, sem dependencia do Flutter.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

class PtzException implements Exception {
  const PtzException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Cabecalho WS-Security com senha em digest:
/// Base64(SHA1(nonce + created + senha)). A senha nunca trafega em claro.
String wsSecurityHeader({required String user, required String password, Uint8List? nonce, DateTime? now}) {
  final n = nonce ?? Uint8List.fromList(List.generate(16, (_) => Random.secure().nextInt(256)));
  final created = '${(now ?? DateTime.now()).toUtc().toIso8601String().split('.').first}Z';
  final digest = sha1.convert([...n, ...utf8.encode(created), ...utf8.encode(password)]).bytes;
  const wsse = 'http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd';
  const wsu = 'http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd';
  const base = 'http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss';
  return '<s:Header><Security s:mustUnderstand="1" xmlns="$wsse"><UsernameToken>'
      '<Username>${_xml(user)}</Username>'
      '<Password Type="$base-username-token-profile-1.0#PasswordDigest">${base64.encode(digest)}</Password>'
      '<Nonce EncodingType="$base-soap-message-security-1.0#Base64Binary">${base64.encode(n)}</Nonce>'
      '<Created xmlns="$wsu">$created</Created>'
      '</UsernameToken></Security></s:Header>';
}

String _xml(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

/// Extrai o caminho de um servico anunciado, ignorando o host.
///
/// Estas cameras anunciam o endereco com um IP de fabrica que nao existe na
/// rede, como http://192.168.1.10:8899/onvif/ptz_service. So o caminho presta.
String? servicePath(String capabilitiesXml, String service) {
  final m = RegExp(
    '<[A-Za-z0-9]*:?$service>.*?<[A-Za-z0-9]*:?XAddr>([^<]+)<',
    dotAll: true,
  ).firstMatch(capabilitiesXml);
  if (m == null) return null;
  final uri = Uri.tryParse(m.group(1)!.trim());
  return (uri == null || uri.path.isEmpty) ? null : uri.path;
}

/// Primeiro token de perfil de midia de uma resposta GetProfiles.
String? firstProfileToken(String profilesXml) =>
    RegExp(r'<[A-Za-z0-9]*:?Profiles\b[^>]*\btoken="([^"]+)"').firstMatch(profilesXml)?.group(1);

/// Motivo legivel de uma falha SOAP, sem repetir o XML inteiro.
String faultReason(String xml) {
  final text = RegExp(r'<[A-Za-z0-9]*:?Text[^>]*>([^<]+)<').firstMatch(xml)?.group(1);
  final sub = RegExp(r'<[A-Za-z0-9]*:?Subcode>\s*<[A-Za-z0-9]*:?Value>([^<]+)<').firstMatch(xml)?.group(1);
  return [text, sub].whereType<String>().map((s) => s.trim()).where((s) => s.isNotEmpty).join(' | ');
}

class OnvifPtz {
  OnvifPtz({
    required this.ip,
    required this.user,
    required this.password,
    this.port = 8899,
    this.invertPan = false,
    this.invertTilt = false,
  });

  final String ip;
  final String user;
  final String password;
  final int port;
  final bool invertPan;
  final bool invertTilt;

  static const _timeout = Duration(seconds: 4);
  String _mediaPath = '/onvif/media_service';
  String _ptzPath = '/onvif/ptz_service';
  String? _profile;
  Future<void>? _ready;

  /// Descobre os caminhos dos servicos e o perfil de midia. Feito uma vez.
  Future<void> prepare() => _ready ??= _prepare().catchError((Object e) {
    _ready = null;
    throw e;
  });

  Future<void> _prepare() async {
    final caps = await _post(
      '/onvif/device_service',
      '<GetCapabilities xmlns="http://www.onvif.org/ver10/device/wsdl"><Category>All</Category></GetCapabilities>',
      auth: false,
    );
    final ptz = servicePath(caps, 'PTZ');
    if (ptz == null) throw const PtzException('Esta câmera não anuncia controle de movimento.');
    _ptzPath = ptz;
    _mediaPath = servicePath(caps, 'Media') ?? _mediaPath;
    final profiles = await _post(_mediaPath, '<GetProfiles xmlns="http://www.onvif.org/ver10/media/wsdl"/>');
    _profile = firstProfileToken(profiles);
    if (_profile == null) throw const PtzException('A câmera não informou um perfil de vídeo.');
  }

  /// Move de forma continua. x e y vao de -1 a 1: x positivo e direita, y positivo e cima.
  Future<void> move(double x, double y) async {
    await prepare();
    if (invertPan) x = -x;
    if (invertTilt) y = -y;
    await _post(
      _ptzPath,
      '<ContinuousMove xmlns="http://www.onvif.org/ver20/ptz/wsdl">'
      '<ProfileToken>${_xml(_profile!)}</ProfileToken>'
      '<Velocity><PanTilt x="${x.toStringAsFixed(2)}" y="${y.toStringAsFixed(2)}" '
      'xmlns="http://www.onvif.org/ver10/schema"/></Velocity>'
      '</ContinuousMove>',
    );
  }

  Future<void> stop() async {
    if (_profile == null) return;
    await _post(
      _ptzPath,
      '<Stop xmlns="http://www.onvif.org/ver20/ptz/wsdl">'
      '<ProfileToken>${_xml(_profile!)}</ProfileToken><PanTilt>true</PanTilt><Zoom>true</Zoom></Stop>',
    );
  }

  Future<String> _post(String path, String body, {bool auth = true}) async {
    final envelope =
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">'
        '${auth ? wsSecurityHeader(user: user, password: password) : ''}'
        '<s:Body>$body</s:Body></s:Envelope>';
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final req = await client.postUrl(Uri(scheme: 'http', host: ip, port: port, path: path)).timeout(_timeout);
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/soap+xml; charset=utf-8');
      // Sem o tamanho explicito o Dart envia em modo chunked, e o servidor ONVIF
      // destas cameras fecha a conexao sem responder.
      final bytes = utf8.encode(envelope);
      req.contentLength = bytes.length;
      req.add(bytes);
      final res = await req.close().timeout(_timeout);
      final text = await res.transform(const Utf8Decoder(allowMalformed: true)).join().timeout(_timeout);
      if (res.statusCode == 401 || text.contains('NotAuthorized') || text.contains('Unauthorized')) {
        throw const PtzException('A câmera recusou o usuário ou a senha.');
      }
      if (res.statusCode >= 400 || text.contains(':Fault>')) {
        final reason = faultReason(text);
        throw PtzException('A câmera recusou o comando${reason.isEmpty ? '' : ': $reason'}.');
      }
      return text;
    } on PtzException {
      rethrow;
    } on TimeoutException {
      throw const PtzException('A câmera não respondeu ao comando.');
    } on SocketException {
      throw const PtzException('Não foi possível falar com a câmera.');
    } on HttpException {
      throw const PtzException('A câmera encerrou a conexão do comando.');
    } finally {
      client.close(force: true);
    }
  }
}
