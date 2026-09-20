import 'package:camwall_app/models/camera.dart';
import 'package:camwall_app/services/discovery.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('normalizeMac', () {
    test('aceita os formatos comuns', () {
      expect(normalizeMac('02:1A:2B:CE:41:F5'), '02:1a:2b:ce:41:f5');
      expect(normalizeMac('02-1a-2b-ce-41-f5'), '02:1a:2b:ce:41:f5');
      expect(normalizeMac('021a2bce41f5'), '02:1a:2b:ce:41:f5');
      expect(normalizeMac('021a.2bce.41f5'), '02:1a:2b:ce:41:f5');
      expect(normalizeMac(' 2:1a:2b:ba:b3:8e '), '02:1a:2b:ba:b3:8e');
    });
    test('rejeita valores invalidos', () {
      for (final bad in [
        '',
        'zz:zz:zz:zz:zz:zz',
        '02:1a:2b:ce:41',
        '02:1a:2b:ce:41:f5:00',
        '021a2bce41f',
        '123:a8:29:ce:41:f5',
      ]) {
        expect(normalizeMac(bad), isNull, reason: bad);
      }
    });
  });

  group('Camera.buildUrl', () {
    const cam = Camera(id: 'a', name: 'Portao', mac: '02:1a:2b:ce:41:f5', user: 'admin');
    test('monta a URL Xiongmai com a imagem certa', () {
      expect(
        cam.buildUrl(ip: '192.168.0.4', password: 'abc123', mainStream: true),
        'rtsp://192.168.0.4:554/user=admin&password=abc123&channel=1&stream=0.sdp?real_stream',
      );
      expect(
        cam.buildUrl(ip: '192.168.0.9', password: '', mainStream: false),
        'rtsp://192.168.0.9:554/user=admin&password=&channel=1&stream=1.sdp?real_stream',
      );
    });
    test('codifica simbolos que quebrariam a URL', () {
      final url = cam.buildUrl(ip: '10.0.0.2', password: 'a&b #1', mainStream: true);
      expect(url, contains('password=a%26b%20%231&'));
    });
    test('cadastro antigo, sem os campos de sentido, ganha o padrao Xiongmai', () {
      final old = Camera.fromJson({'id': 'a', 'name': 'x', 'mac': '02:1a:2b:ce:41:f5'})!;
      expect(old.invertPan, isTrue);
      expect(old.invertTilt, isFalse);
      final back = Camera.fromJson(old.copyWith(invertPan: false, invertTilt: true, serial: 'SN123').toJson())!;
      expect(back.invertPan, isFalse);
      expect(back.invertTilt, isTrue);
      expect(back.serial, 'SN123', reason: 'sem a serie gravada, o app esquece as duas interfaces ao reabrir');
    });
    test('sobrevive a ida e volta em JSON sem carregar senha', () {
      final json = cam.copyWith(lastIp: '192.168.0.4', lastSeen: 10).toJson();
      expect(json.keys, isNot(contains('password')));
      final back = Camera.fromJson(json)!;
      expect(back.mac, cam.mac);
      expect(back.lastIp, '192.168.0.4');
      expect(back.template, kDefaultTemplate);
    });
  });

  group('validateTemplate', () {
    test('aceita o padrao, vazio e variantes validas', () {
      expect(validateTemplate(kDefaultTemplate), isNull);
      expect(validateTemplate(''), isNull);
      expect(validateTemplate('rtsp://{user}:{password}@{ip}:554/Streaming/Channels/10{stream}'), isNull);
    });
    test('rejeita modelos sem ip, protocolo estranho e marcador desconhecido', () {
      expect(validateTemplate('rtsp://192.168.0.4/stream'), isNotNull);
      expect(validateTemplate('ftp://{ip}/x'), isNotNull);
      expect(validateTemplate('rtsp://{ip}/{canal}'), isNotNull);
    });
  });
}
