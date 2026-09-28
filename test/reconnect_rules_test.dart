import 'package:camwall_app/widgets/camera_tile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('primeira nova tentativa é quase imediata e as seguintes crescem até um teto', () {
    expect(retryDelay(0), const Duration(milliseconds: 500));
    expect(retryDelay(1), const Duration(seconds: 1));
    expect(retryDelay(2), const Duration(seconds: 2));
    expect(retryDelay(5), const Duration(seconds: 15));
    expect(retryDelay(50), const Duration(seconds: 15));
    expect(retryDelay(-1), const Duration(milliseconds: 500));
  });

  test('reconhece os erros que deixam o quadro cinza', () {
    // Mensagens reais do iPhone e do Android.
    expect(isDecodeErrorLog('hevc: Could not find ref with POC 5'), isTrue);
    expect(isDecodeErrorLog('Error while decoding frame (hardware decoding)!'), isTrue);
    expect(isDecodeErrorLog('hevc: hardware accelerator failed to decode picture'), isTrue);
    expect(isDecodeErrorLog('hevc: vt decoder cb: output image buffer is null: -17694'), isTrue);
    expect(isDecodeErrorLog('Invalid video timestamp: 65.250022 -> 65.166700'), isFalse);
    expect(isDecodeErrorLog('Reading plaintext playlist.'), isFalse);
  });
}
