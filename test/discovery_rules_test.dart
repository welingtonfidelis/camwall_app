import 'package:camwall_app/services/discovery.dart';
import 'package:flutter_test/flutter_test.dart';

DiscoveredCamera dev(String mac, String ip, {String serial = 'SN1', String hostname = 'camera_0419'}) =>
    DiscoveredCamera(mac: mac, ip: ip, serial: serial, hostname: hostname, version: '');

void main() {
  const wifi = '02:1a:2b:54:04:19';
  const eth = '02:1a:2b:ba:b3:8e';

  group('groupBySerial', () {
    test('junta as duas interfaces da mesma camera e poe o Wi-Fi na frente', () {
      final groups = groupBySerial([
        dev(eth, '192.168.0.2'),
        dev('02:1a:2b:ce:41:f5', '192.168.0.4', serial: 'SN2', hostname: 'camera_41f5'),
        dev(wifi, '192.168.0.5'),
      ]);
      expect(groups, hasLength(2));
      final gate = groups.firstWhere((g) => g.serial == 'SN1');
      expect(gate.interfaces, hasLength(2));
      expect(gate.primary.mac, wifi, reason: 'o MAC que termina como o hostname e o principal');
      expect(gate.macs, {wifi, eth});
    });
    test('sem numero de serie, cada MAC vira uma camera', () {
      final groups = groupBySerial([dev(eth, '10.0.0.2', serial: ''), dev(wifi, '10.0.0.3', serial: '')]);
      expect(groups, hasLength(2));
    });
  });

  group('pickIp', () {
    String? pick(
      List<DiscoveredCamera> found, {
      String lastIp = '192.168.0.5',
      int misses = 0,
      String serial = 'SN1',
    }) => pickIp(mac: wifi, serial: serial, lastIp: lastIp, misses: misses, found: found);

    test('mantem o IP atual enquanto ele responde', () {
      expect(pick([dev(wifi, '192.168.0.5'), dev(eth, '192.168.0.2')]), '192.168.0.5');
    });
    test('troca na hora quando o MAC cadastrado aparece em outro IP', () {
      expect(pick([dev(wifi, '192.168.0.9')]), '192.168.0.9');
    });
    test('nao pula para a outra interface por causa de uma unica resposta perdida', () {
      expect(pick([dev(eth, '192.168.0.2')], misses: 0), isNull);
    });
    test('pula para a outra interface quando o IP atual some de novo', () {
      expect(pick([dev(eth, '192.168.0.2')], misses: 1), '192.168.0.2');
    });
    test('depois de pular, fica na interface nova mesmo que a antiga volte', () {
      expect(pick([dev(wifi, '192.168.0.5'), dev(eth, '192.168.0.2')], lastIp: '192.168.0.2'), '192.168.0.2');
    });
    test('primeira resolucao aceita qualquer interface da camera', () {
      expect(pick([dev(eth, '192.168.0.2')], lastIp: ''), '192.168.0.2');
    });
    test('sem numero de serie so vale o MAC', () {
      expect(pick([dev(eth, '192.168.0.2')], serial: '', misses: 5), isNull);
    });
    test('nada respondeu', () {
      expect(pick([]), isNull);
    });
  });
}
