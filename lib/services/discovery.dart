// Descoberta de cameras Xiongmai (apps iCSee e XMEye) na rede local.
//
// O Android 10 em diante bloqueia a leitura da tabela ARP, entao o app nao
// consegue traduzir MAC em IP pelo sistema. Estas cameras, porem, respondem a
// um pedido de descoberta na porta UDP 34569 com MAC, IP e numero de serie,
// sem login. A resposta chega sempre na porta 34569 de quem perguntou, por isso
// o socket precisa estar preso nessa porta.
//
// O pedido vai de duas formas ao mesmo tempo:
// - broadcast, que alcanca a rede inteira com um pacote. O iOS so permite
//   broadcast com uma autorizacao especial da Apple, e alguns roteadores o filtram;
// - unicast para cada endereco da sub-rede, que funciona em qualquer plataforma
//   so com a permissao de rede local. As cameras respondem igual.
//
// Dart puro, sem dependencia do Flutter: pode ser testado com `dart run`.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class DiscoveredCamera {
  const DiscoveredCamera({
    required this.mac,
    required this.ip,
    required this.serial,
    required this.hostname,
    required this.version,
  });

  final String mac;
  final String ip;
  final String serial;
  final String hostname;
  final String version;

  @override
  String toString() => '$mac  $ip  $hostname  serie $serial';
}

/// Aceita 02:1A:2B:CE:41:F5, 02-1a-2b-ce-41-f5, 021a2bce41f5 e 2:1a:2b:ba:b3:8e.
String? normalizeMac(String value) {
  var s = value.trim().toLowerCase();
  List<String> parts;
  if (s.contains(':') || s.contains('-')) {
    parts = s.split(RegExp(r'[:\-]'));
  } else {
    s = s.replaceAll('.', '').replaceAll(' ', '');
    if (s.length != 12) return null;
    parts = [for (var i = 0; i < 12; i += 2) s.substring(i, i + 2)];
  }
  if (parts.length != 6) return null;
  final octet = RegExp(r'^[0-9a-f]{1,2}$');
  if (!parts.every(octet.hasMatch)) return null;
  return parts.map((p) => p.padLeft(2, '0')).join(':');
}

/// Uma camera fisica encontrada na rede, juntando as interfaces que tem o mesmo
/// numero de serie.
class FoundCamera {
  const FoundCamera(this.interfaces);

  /// A primeira e a interface principal.
  final List<DiscoveredCamera> interfaces;

  DiscoveredCamera get primary => interfaces.first;
  Set<String> get macs => {for (final i in interfaces) i.mac};
  String get serial => primary.serial;
}

/// Agrupa as respostas por numero de serie. A interface principal e aquela cujo
/// MAC termina como o nome de rede da camera, por exemplo `camera_0419` e
/// `...:04:19`, que nestas cameras e o radio Wi-Fi.
List<FoundCamera> groupBySerial(List<DiscoveredCamera> devices) {
  final groups = <String, List<DiscoveredCamera>>{};
  for (final d in devices) {
    groups.putIfAbsent(d.serial.isEmpty ? 'mac:${d.mac}' : d.serial, () => []).add(d);
  }
  bool matchesHostname(DiscoveredCamera d) {
    final tail = d.mac.replaceAll(':', '');
    return d.hostname.toLowerCase().endsWith(tail.substring(tail.length - 4));
  }

  return [
    for (final g in groups.values) FoundCamera([...g.where(matchesHostname), ...g.where((d) => !matchesHostname(d))]),
  ];
}

/// Decide o IP de uma camera cadastrada a partir do que respondeu na rede.
///
/// Devolve o IP a usar, ou null se a camera nao foi vista nesta varredura.
/// - Se o IP atual continua respondendo por qualquer interface da camera, ele e
///   mantido. Isso evita ficar alternando entre as duas interfaces.
/// - Se o MAC cadastrado respondeu em outro IP, troca na hora: o IP mudou.
/// - Se so outra interface da mesma camera respondeu, a troca espera uma
///   varredura sem resposta do IP atual, porque respostas se perdem no Wi-Fi.
String? pickIp({
  required String mac,
  required String serial,
  required String lastIp,
  required int misses,
  required List<DiscoveredCamera> found,
}) {
  String? macIp;
  final serialIps = <String>[];
  for (final d in found) {
    if (d.mac == mac) macIp ??= d.ip;
    if (serial.isNotEmpty && d.serial == serial) serialIps.add(d.ip);
  }
  if (lastIp.isNotEmpty && (macIp == lastIp || serialIps.contains(lastIp))) return lastIp;
  if (macIp != null) return macIp;
  if (serialIps.isNotEmpty && (lastIp.isEmpty || misses >= 1)) return serialIps.first;
  return null;
}

class XmDiscovery {
  static const int port = 34569;
  static Future<List<DiscoveredCamera>>? _inFlight;

  /// Varre a rede. Chamadas simultaneas compartilham a mesma varredura, porque
  /// so um socket pode ficar preso na porta 34569 por vez.
  ///
  /// `useBroadcast: false` reproduz a restricao do iOS e serve para testar o
  /// caminho so com unicast em qualquer plataforma.
  static Future<List<DiscoveredCamera>> discover({
    Duration timeout = const Duration(seconds: 3),
    Iterable<String> knownIps = const [],
    bool useBroadcast = true,
  }) {
    return _inFlight ??= _discover(timeout, knownIps.toList(), useBroadcast).whenComplete(() => _inFlight = null);
  }

  static Uint8List _packet() {
    final p = Uint8List(20);
    p[0] = 0xff;
    ByteData.view(p.buffer).setUint16(14, 1530, Endian.little); // IPSEARCH_REQ
    return p;
  }

  /// Interfaces que nao sao a rede local: dados moveis, VPN e enlaces da Apple.
  static const _ignoredInterfaces = ['pdp_ip', 'rmnet', 'ccmni', 'utun', 'tun', 'ppp', 'ipsec', 'awdl', 'llw', 'lo'];

  static bool _isPrivate(List<int> o) =>
      o[0] == 10 || (o[0] == 172 && o[1] >= 16 && o[1] <= 31) || (o[0] == 192 && o[1] == 168);

  /// Prefixos "a.b.c" das redes locais desta maquina, assumindo mascara /24.
  static Future<List<String>> _localPrefixes() async {
    final out = <String>{};
    try {
      final ifaces = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
      for (final iface in ifaces) {
        final name = iface.name.toLowerCase();
        if (_ignoredInterfaces.any(name.startsWith)) continue;
        for (final addr in iface.addresses) {
          final o = addr.address.split('.').map(int.tryParse).toList();
          if (o.length != 4 || o.contains(null)) continue;
          final octets = o.cast<int>();
          if (_isPrivate(octets)) out.add('${octets[0]}.${octets[1]}.${octets[2]}');
        }
      }
    } catch (_) {}
    return out.toList();
  }

  /// Envia o pedido a todos os alvos por um socket descartavel.
  ///
  /// O Dart fecha o socket inteiro ao primeiro erro de envio, e erros sao
  /// normais aqui: o iOS recusa broadcast sem autorizacao da Apple e o macOS
  /// recusa hosts que ja sabe estarem fora do ar. Por isso quem envia nunca e o
  /// socket que escuta. As cameras respondem sempre para a porta 34569, nao para
  /// a porta de origem, entao a resposta chega ao socket de escuta do mesmo jeito.
  static Future<void> _burst(Uint8List packet, Iterable<String> targets, {required bool broadcast}) async {
    RawDatagramSocket sender;
    try {
      sender = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    } on SocketException {
      return;
    }
    // Sem onError, a falha de envio viraria excecao nao tratada.
    sender.listen((_) {}, onError: (Object _) {});
    try {
      if (broadcast) sender.broadcastEnabled = true;
      // O fechamento por erro so acontece depois deste laco sincrono, entao
      // todos os pacotes da rodada saem mesmo que alguns alvos falhem.
      for (final t in targets) {
        try {
          sender.send(packet, InternetAddress(t), port);
        } catch (_) {}
      }
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 50));
    sender.close();
  }

  static Future<List<DiscoveredCamera>> _discover(Duration timeout, List<String> knownIps, bool useBroadcast) async {
    RawDatagramSocket listener;
    try {
      listener = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port, reuseAddress: true);
    } on SocketException {
      return const [];
    }
    final prefixes = await _localPrefixes();
    final broadcasts = <String>{'255.255.255.255', for (final p in prefixes) '$p.255'};
    final known = knownIps.where((ip) => ip.isNotEmpty).toSet();
    // Varredura unicast da sub-rede, para onde o broadcast nao passa, como no iOS.
    final sweep = <String>[
      for (final p in prefixes)
        for (var h = 1; h < 255; h++) '$p.$h',
    ];
    final packet = _packet();
    final found = <String, DiscoveredCamera>{};

    final sub = listener.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? dg;
      while ((dg = listener.receive()) != null) {
        final cam = _parse(dg!);
        if (cam != null) found.putIfAbsent(cam.mac, () => cam);
      }
    }, onError: (Object _) {});

    // Wi-Fi perde pacotes, entao os pedidos sao repetidos durante a escuta:
    // broadcast e IPs conhecidos a cada 700 ms, varredura completa a cada 1400 ms.
    var round = 0;
    void tick() {
      unawaited(_burst(packet, known, broadcast: false));
      if (useBroadcast) unawaited(_burst(packet, broadcasts, broadcast: true));
      if (round.isEven) unawaited(_burst(packet, sweep, broadcast: false));
      round++;
    }

    tick();
    final resend = Timer.periodic(const Duration(milliseconds: 700), (_) => tick());
    await Future<void>.delayed(timeout);
    resend.cancel();
    await sub.cancel();
    listener.close();

    final list = found.values.toList()..sort((a, b) => _ipKey(a.ip).compareTo(_ipKey(b.ip)));
    return list;
  }

  static int _ipKey(String ip) {
    final o = ip.split('.').map(int.tryParse).toList();
    if (o.length != 4 || o.contains(null)) return 0;
    return (o[0]! << 24) | (o[1]! << 16) | (o[2]! << 8) | o[3]!;
  }

  static DiscoveredCamera? _parse(Datagram dg) {
    final data = dg.data;
    if (data.length <= 20) return null;
    var end = data.length;
    while (end > 20 && (data[end - 1] == 0 || data[end - 1] == 10 || data[end - 1] == 13 || data[end - 1] == 32)) {
      end--;
    }
    try {
      final json = jsonDecode(utf8.decode(data.sublist(20, end), allowMalformed: true));
      if (json is! Map) return null;
      final nc = json['NetWork.NetCommon'];
      if (nc is! Map) return null;
      final mac = normalizeMac('${nc['MAC'] ?? ''}');
      if (mac == null) return null;
      return DiscoveredCamera(
        mac: mac,
        ip: dg.address.address,
        serial: '${nc['SN'] ?? ''}',
        hostname: '${nc['HostName'] ?? ''}',
        version: '${nc['Version'] ?? ''}',
      );
    } catch (_) {
      return null;
    }
  }
}
