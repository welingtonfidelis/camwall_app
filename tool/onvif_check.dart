// ignore_for_file: avoid_print
// Diagnostico sem login: a camera aceita o corpo do pedido em modo chunked?
//   dart run tool/onvif_check.dart 192.168.0.10
import 'dart:convert';
import 'dart:io';

Future<void> attempt(String ip, {required bool withLength}) async {
  const body = '<?xml version="1.0" encoding="UTF-8"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">'
      '<s:Body><GetCapabilities xmlns="http://www.onvif.org/ver10/device/wsdl"><Category>All</Category>'
      '</GetCapabilities></s:Body></s:Envelope>';
  final bytes = utf8.encode(body);
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
  final label = withLength ? 'com Content-Length' : 'chunked, padrao do Dart';
  try {
    final req = await client.postUrl(Uri.parse('http://$ip:8899/onvif/device_service'));
    req.headers.set(HttpHeaders.contentTypeHeader, 'application/soap+xml; charset=utf-8');
    if (withLength) req.contentLength = bytes.length;
    req.add(bytes);
    final res = await req.close().timeout(const Duration(seconds: 5));
    final text = await res.transform(utf8.decoder).join();
    print('$label: HTTP ${res.statusCode}, ${text.length} bytes, PTZ anunciado: ${text.contains('ptz_service')}');
  } catch (e) {
    print('$label: FALHOU -> ${e.runtimeType}: $e');
  } finally {
    client.close(force: true);
  }
}

Future<void> main(List<String> args) async {
  final ip = args.isEmpty ? '192.168.0.10' : args.first;
  await attempt(ip, withLength: false);
  await attempt(ip, withLength: true);
}
