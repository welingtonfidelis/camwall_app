import 'dart:math';

/// Modelo padrao das cameras Xiongmai. `{stream}` e 0 para a imagem principal
/// e 1 para a secundaria, mais leve.
const String kDefaultTemplate =
    'rtsp://{ip}:554/user={user}&password={password}&channel=1&stream={stream}.sdp?real_stream';

const Set<String> kAllowedSchemes = {'rtsp', 'rtsps', 'http', 'https'};

class Camera {
  const Camera({
    required this.id,
    required this.name,
    required this.mac,
    required this.user,
    this.template = kDefaultTemplate,
    this.serial = '',
    this.invertPan = true,
    this.invertTilt = false,
    this.lastIp = '',
    this.lastSeen = 0,
  });

  final String id;
  final String name;
  final String mac;
  final String user;
  final String template;

  /// Numero de serie, preenchido quando a camera e cadastrada pela busca na
  /// rede. Algumas cameras respondem por duas interfaces, cada uma com seu MAC:
  /// o numero de serie permite reconhece-las como o mesmo aparelho.
  final String serial;

  /// Sentido das setas de movimento. As cameras Xiongmai respondem ao ONVIF com
  /// esquerda e direita trocadas, por isso o padrao ja vem invertido. Uma camera
  /// montada de cabeca para baixo pode precisar do contrario.
  final bool invertPan;
  final bool invertTilt;

  /// Ultimo IP em que a camera foi vista. Permite abrir o video na hora,
  /// antes de a primeira varredura terminar.
  final String lastIp;
  final int lastSeen;

  static String newId() {
    final r = Random.secure();
    return List.generate(8, (_) => r.nextInt(16).toRadixString(16)).join();
  }

  Camera copyWith({
    String? name,
    String? mac,
    String? user,
    String? template,
    String? serial,
    bool? invertPan,
    bool? invertTilt,
    String? lastIp,
    int? lastSeen,
  }) {
    return Camera(
      id: id,
      name: name ?? this.name,
      mac: mac ?? this.mac,
      user: user ?? this.user,
      template: template ?? this.template,
      serial: serial ?? this.serial,
      invertPan: invertPan ?? this.invertPan,
      invertTilt: invertTilt ?? this.invertTilt,
      lastIp: lastIp ?? this.lastIp,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }

  /// A senha nao faz parte do modelo salvo: ela fica no armazenamento seguro.
  String buildUrl({required String ip, required String password, required bool mainStream}) {
    return template
        .replaceAll('{ip}', ip)
        .replaceAll('{user}', Uri.encodeComponent(user))
        .replaceAll('{password}', Uri.encodeComponent(password))
        .replaceAll('{stream}', mainStream ? '0' : '1');
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'mac': mac,
    'user': user,
    'template': template,
    'serial': serial,
    'invertPan': invertPan,
    'invertTilt': invertTilt,
    'lastIp': lastIp,
    'lastSeen': lastSeen,
  };

  static Camera? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'], mac = json['mac'];
    if (id is! String || mac is! String || id.isEmpty) return null;
    return Camera(
      id: id,
      name: '${json['name'] ?? ''}',
      mac: mac,
      user: '${json['user'] ?? ''}',
      template: (json['template'] is String && (json['template'] as String).contains('{ip}'))
          ? json['template'] as String
          : kDefaultTemplate,
      serial: '${json['serial'] ?? ''}',
      invertPan: json['invertPan'] is bool ? json['invertPan'] as bool : true,
      invertTilt: json['invertTilt'] is bool ? json['invertTilt'] as bool : false,
      lastIp: '${json['lastIp'] ?? ''}',
      lastSeen: json['lastSeen'] is int ? json['lastSeen'] as int : 0,
    );
  }
}

/// Devolve a mensagem de erro, ou null se o modelo de URL for valido.
String? validateTemplate(String template) {
  final t = template.trim();
  if (t.isEmpty) return null; // vazio significa usar o padrao
  if (t.length > 500 || t.runes.any((c) => c < 32 || c == 127)) {
    return 'Modelo de URL inválido.';
  }
  if (!t.contains('{ip}')) return 'O modelo precisa conter {ip}.';
  final scheme = t.contains('://') ? t.split('://').first.toLowerCase() : '';
  if (!kAllowedSchemes.contains(scheme)) {
    return 'Use rtsp, rtsps, http ou https.';
  }
  final unknown = RegExp(r'\{(?!ip\}|user\}|password\}|stream\})[^}]*\}').hasMatch(t);
  if (unknown) return 'Marcadores aceitos: {ip} {user} {password} {stream}.';
  return null;
}
