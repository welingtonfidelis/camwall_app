import 'dart:convert';
import 'dart:typed_data';

import 'package:camwall_app/services/onvif_ptz.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('digest WS-Security confere com o exemplo da especificacao ONVIF', () {
    // ONVIF Application Programmer's Guide, secao 6.1.1.3.
    final header = wsSecurityHeader(
      user: 'admin',
      password: 'userpassword',
      nonce: Uint8List.fromList(base64.decode('LKqI6G/AikKCQrN0zqZFlg==')),
      now: DateTime.utc(2010, 9, 16, 7, 50, 45),
    );
    expect(header, contains('>tuOSpGlFlIXsozq4HFNeeGeFLEI=<'));
    expect(header, contains('>2010-09-16T07:50:45Z<'));
    expect(header, isNot(contains('userpassword')), reason: 'a senha nunca vai em claro');
  });

  test('usa so o caminho do servico, porque a camera anuncia um IP de fabrica errado', () {
    const caps =
        '<tt:Media><tt:XAddr>http://192.168.1.10:8899/onvif/media_service</tt:XAddr></tt:Media>'
        '<tt:PTZ><tt:XAddr>http://192.168.1.10:8899/onvif/ptz_service</tt:XAddr></tt:PTZ>';
    expect(servicePath(caps, 'PTZ'), '/onvif/ptz_service');
    expect(servicePath(caps, 'Media'), '/onvif/media_service');
    expect(servicePath(caps, 'Imaging'), isNull);
  });

  test('le o token do primeiro perfil', () {
    const xml =
        '<trt:GetProfilesResponse><trt:Profiles fixed="true" token="000"><tt:Name>main</tt:Name></trt:Profiles>'
        '<trt:Profiles token="001"/></trt:GetProfilesResponse>';
    expect(firstProfileToken(xml), '000');
    expect(firstProfileToken('<x/>'), isNull);
  });

  test('resume o motivo de uma falha SOAP', () {
    const fault =
        '<s:Fault><s:Code><s:Value>s:Sender</s:Value><s:Subcode><s:Value>ter:NotAuthorized</s:Value>'
        '</s:Subcode></s:Code><s:Reason><s:Text xml:lang="en">Sender not authorized</s:Text></s:Reason></s:Fault>';
    expect(faultReason(fault), 'Sender not authorized | ter:NotAuthorized');
  });
}
