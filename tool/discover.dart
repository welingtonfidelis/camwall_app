// ignore_for_file: avoid_print
// Teste de linha de comando da descoberta:
//   dart run tool/discover.dart                 broadcast e unicast, como no Android
//   dart run tool/discover.dart --no-broadcast  so unicast, como no iOS
import 'package:camwall_app/services/discovery.dart';

Future<void> main(List<String> args) async {
  final useBroadcast = !args.contains('--no-broadcast');
  print(useBroadcast ? 'modo: broadcast e unicast' : 'modo: so unicast, como no iOS');
  for (var i = 1; i <= 3; i++) {
    final sw = Stopwatch()..start();
    final cams = await XmDiscovery.discover(useBroadcast: useBroadcast);
    print('varredura $i: ${cams.length} cameras em ${sw.elapsedMilliseconds} ms');
    for (final c in cams) {
      print('  $c');
    }
  }
}
