import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// Registro de diagnostico no log. Ligado em modo de depuracao, ou em qualquer
/// build com `--dart-define=CAMWALL_DIAG=true`.
const bool _diag = kDebugMode || bool.fromEnvironment('CAMWALL_DIAG');

/// Apenas para desenvolvimento: `--dart-define=CAMWALL_DEBUG_DROP_EVERY=25` força uma
/// reconexão a cada tantos segundos de vídeo, para medir a recuperação.
const int _debugDropEvery = int.fromEnvironment('CAMWALL_DEBUG_DROP_EVERY');

/// Apenas para desenvolvimento: `--dart-define=CAMWALL_DEBUG_TIMED=true` volta a
/// obedecer às marcações de tempo da câmera, para comparar o atraso.
const bool _debugTimed = bool.fromEnvironment('CAMWALL_DEBUG_TIMED');

/// Apenas para desenvolvimento: `--dart-define=CAMWALL_DEBUG_SPEED=1.04` reproduz
/// nessa velocidade, para casar com a taxa real de quadros da câmera.
const String _debugSpeed = String.fromEnvironment('CAMWALL_DEBUG_SPEED');

enum _Phase { searching, connecting, live, retrying, authError }

/// Espera antes de cada nova tentativa, em milissegundos. A primeira é quase
/// imediata, porque a maioria das quedas é momentânea.
const List<int> _backoffMs = [500, 1000, 2000, 4000, 8000, 15000];

@visibleForTesting
Duration retryDelay(int failures) => Duration(milliseconds: _backoffMs[failures.clamp(0, _backoffMs.length - 1)]);

/// Mensagem do mpv que indica quadro decodificado sem a referência, que aparece
/// cinza na tela.
@visibleForTesting
bool isDecodeErrorLog(String text) =>
    text.contains('Could not find ref') ||
    text.contains('Error while decoding') ||
    text.contains('failed to decode picture') ||
    text.contains('output image buffer is null');

/// Liga a tela ao player, para pedir uma foto do quadro atual.
class CameraTileController {
  _CameraTileState? _state;

  bool get isLive => _state?._phase == _Phase.live;

  /// Quadro atual em JPEG, ou null se o vídeo ainda não estiver tocando.
  Future<Uint8List?> capture() async => _state?._capture();
}

/// Como mostrar o quadro de uma camera de duas lentes. Essas cameras enviam um
/// unico video com as duas imagens empilhadas: a lente 0 em cima e a 1 embaixo.
enum LensView {
  /// O quadro inteiro, como a camera envia.
  whole,

  /// So a imagem de cima.
  top,

  /// So a imagem de baixo.
  bottom,

  /// As duas imagens lado a lado, para tela deitada.
  sideBySide,
}

/// Um video ao vivo. Cuida sozinho de conectar, detectar imagem congelada e
/// reconectar. Quando a URL muda, por exemplo porque o IP mudou, reabre.
class CameraTile extends StatefulWidget {
  const CameraTile({
    super.key,
    required this.name,
    required this.url,
    required this.online,
    this.active = true,
    this.zoomable = false,
    this.lensView = LensView.whole,
    this.muted = true,
    this.tileController,
    this.onTap,
    this.onLensTap,
    this.onDualLens,
    this.onNeedRescan,
  });

  final String name;

  /// null enquanto o IP da camera ainda nao foi descoberto.
  final String? url;
  final bool online;

  /// false pausa a conexao, por exemplo quando outra tela esta por cima.
  final bool active;
  final bool zoomable;
  final LensView lensView;

  /// O som da câmera. Desligado por padrão: no mural várias câmeras tocariam juntas.
  final bool muted;

  /// Permite à tela pedir uma foto do quadro atual.
  final CameraTileController? tileController;
  final VoidCallback? onTap;

  /// Toque numa das imagens de uma camera de duas lentes: 0 e a de cima.
  final ValueChanged<int>? onLensTap;

  /// Avisa quando o video revela se a camera tem duas lentes.
  final ValueChanged<bool>? onDualLens;

  /// Chamado quando a conexao falha: o IP pode ter mudado.
  final VoidCallback? onNeedRescan;

  @override
  State<CameraTile> createState() => _CameraTileState();
}

class _CameraTileState extends State<CameraTile> {
  /// Sem quadro novo por este tempo, com o vídeo já tocando: a conexão travou.
  static const _stallLive = Duration(seconds: 6);

  /// Tolerância para o primeiro quadro depois de abrir a conexão.
  static const _stallStart = Duration(seconds: 10);

  /// Sem quadro novo por este tempo, o nome da câmera ganha o indicador de espera.
  static const _slowAfter = Duration(seconds: 2);

  /// Depois de reconectar, a última imagem fica na frente até o vídeo novo passar
  /// este tempo sem erro de decodificação, o equivalente a três quadros. Nas
  /// medições o único erro da reconexão vem antes do primeiro quadro exibido.
  static const _cleanFor = Duration(milliseconds: 250);

  /// Limite para manter a última imagem com o vídeo novo já tocando.
  static const _frozenMaxLive = Duration(seconds: 6);

  /// Sem conseguir reconectar, a última imagem sai e dá lugar ao aviso, para não
  /// passar uma cena antiga por atual.
  static const _frozenMaxAge = Duration(seconds: 30);

  late final Player _player;
  late final VideoController _controller;
  final List<StreamSubscription<dynamic>> _subs = [];
  Timer? _watchdog;
  Timer? _retryTimer;
  Timer? _errorCheck;
  Duration _lastPos = Duration.zero;
  int _videoW = 0;
  int _videoH = 0;
  int _rawW = 0;
  int _rawH = 0;

  /// Esta conexão já mostrou algum quadro.
  bool _started = false;
  DateTime? _liveSince;
  DateTime? _openedAt;
  DateTime? _failedAt;

  /// Sem quadro novo há mais de [_slowAfter].
  bool _slow = false;

  /// Falha detectada e nova tentativa em preparo.
  bool _recovering = false;

  /// Última imagem, mantida na tela durante a reconexão.
  ui.Image? _frozen;
  DateTime? _frozenAt;
  DateTime _lastDecodeError = DateTime.fromMillisecondsSinceEpoch(0);
  int _ticks = 0;
  bool _reportedDecoder = false;
  DateTime _lastProgress = DateTime.now();
  _Phase _phase = _Phase.searching;
  int _failures = 0;
  String? _openedUrl;
  bool _sawAuthError = false;

  @override
  void initState() {
    super.initState();
    _player = Player(
      configuration: const PlayerConfiguration(
        // O padrao do media_kit nao inclui rtsp: sem isto o video nao abre.
        protocolWhitelist: ['udp', 'rtp', 'tcp', 'tls', 'data', 'file', 'http', 'https', 'crypto', 'rtsp', 'rtsps'],
        bufferSize: 4 * 1024 * 1024,
        logLevel: MPVLogLevel.warn,
      ),
    );
    // No iPhone o decodificador do chip rejeita alguns quadros H.265 destas
    // câmeras e a imagem fica cinza por instantes. No Android o chip aceita.
    _controller = VideoController(
      _player,
      configuration: VideoControllerConfiguration(hwdec: Platform.isIOS ? 'no' : null),
    );
    _subs.add(_player.stream.position.listen(_onPosition));
    _subs.add(
      _player.stream.width.listen((w) {
        _rawW = w ?? 0;
        _applyVideoSize();
      }),
    );
    _subs.add(
      _player.stream.height.listen((h) {
        _rawH = h ?? 0;
        _applyVideoSize();
      }),
    );
    _subs.add(_player.stream.error.listen((_) => _onPlayerError()));
    _subs.add(
      _player.stream.completed.listen((done) {
        if (done) _onFailure('a conexão foi encerrada (fim do stream)');
      }),
    );
    _subs.add(
      _player.stream.log.listen((log) {
        final t = log.text;
        if (t.contains('401') || t.contains('nauthorized')) {
          _sawAuthError = true;
        }
        if (isDecodeErrorLog(t)) _lastDecodeError = DateTime.now();
        if (_diag) {
          debugPrint('[mpv ${widget.name}] ${log.level} ${log.prefix}: ${_maskSecrets(t.trim())}');
        }
      }),
    );
    _subs.add(
      _player.stream.error.listen((e) {
        if (_diag) {
          debugPrint('[player ${widget.name}] erro: ${_maskSecrets(e)}');
        }
      }),
    );
    widget.tileController?._state = this;
    _watchdog = Timer.periodic(const Duration(seconds: 1), (_) => _checkStall());
    _configure().then((_) => _sync());
  }

  /// Ajustes do mpv para video ao vivo: sem cache, sem audio, RTSP por TCP.
  Future<void> _configure() async {
    final native = _player.platform;
    if (native is! NativePlayer) return;
    final props = {
      'rtsp-transport': 'tcp',
      'cache': 'no',
      'cache-on-disk': 'no',
      'cache-pause': 'no',
      'keep-open': 'no',
      'interpolation': 'no',
      'video-latency-hacks': 'yes',
      // As marcações de tempo destas câmeras correm 4% adiantadas: 62,4 s de vídeo
      // a cada 60 s reais, medido nas duas câmeras. Obedecendo a elas, o player
      // atrasa cerca de 2,4 s por minuto de exibição. Mostrar cada quadro assim que
      // chega mantém a imagem no presente.
      if (!_debugTimed && _debugSpeed.isEmpty) 'untimed': 'yes',
      if (_debugSpeed.isNotEmpty) 'speed': _debugSpeed,
      'demuxer-lavf-analyzeduration': '0.5',
      'network-timeout': '5',
    };
    for (final e in props.entries) {
      try {
        await native.setProperty(e.key, e.value);
      } catch (_) {}
    }
    try {
      await native.command(['change-list', 'demuxer-lavf-o', 'add', 'fflags=+nobuffer']);
    } catch (_) {}
    // O mpv fica ocioso quando a tentativa atual termina sem vídeo: a conexão não
    // abriu ou foi encerrada. O media_kit não emite erro nesse caso, e o log não
    // serve: ao reabrir, o cancelamento da tentativa anterior também aparece lá
    // como falha de abertura.
    try {
      await native.observeProperty('idle-active', (value) async {
        if (value == 'yes') _onIdle();
      });
    } catch (_) {}
    await _applyMuted();
  }

  void _onIdle() {
    if (_openedUrl == null || _recovering) return;
    // Confirma um instante depois: ao iniciar, o aviso de ociosidade de antes da
    // primeira abertura pode chegar atrasado, quando o pedido já está em curso.
    Timer(const Duration(milliseconds: 150), () async {
      if (!mounted || _openedUrl == null || _recovering) return;
      final native = _player.platform;
      if (native is! NativePlayer) return;
      try {
        if (await native.getProperty('idle-active') != 'yes') return;
      } catch (_) {
        return;
      }
      _onFailure(_started ? 'a conexão foi encerrada' : 'a conexão não abriu');
    });
  }

  /// Liga ou desliga a trilha de áudio sem reabrir a conexão com a câmera.
  Future<void> _applyMuted() async {
    final native = _player.platform;
    if (native is! NativePlayer) return;
    try {
      await native.setProperty('aid', widget.muted ? 'no' : 'auto');
      if (!widget.muted) await _player.setVolume(100);
    } catch (_) {}
  }

  /// Foto do quadro atual, em JPEG e na resolução do vídeo.
  Future<Uint8List?> _capture() async {
    if (_phase != _Phase.live) return null;
    try {
      return await _player.screenshot(format: 'image/jpeg');
    } catch (_) {
      return null;
    }
  }

  @override
  void didUpdateWidget(CameraTile old) {
    super.didUpdateWidget(old);
    if (old.tileController != widget.tileController) {
      if (old.tileController?._state == this) old.tileController?._state = null;
      widget.tileController?._state = this;
    }
    if (old.muted != widget.muted) _applyMuted();
    if (old.url != widget.url || old.active != widget.active) {
      _failures = 0;
      _sync();
    }
  }

  /// Nunca deixa usuario ou senha aparecerem em log.
  static String _maskSecrets(String text) {
    return text
        .replaceAll(RegExp(r'password=[^&\s]*'), 'password=***')
        .replaceAll(RegExp(r'user=[^&\s]*'), 'user=***')
        .replaceAll(RegExp(r'://[^/@\s]+@'), '://***@');
  }

  void _setPhase(_Phase p) {
    if (mounted && _phase != p) setState(() => _phase = p);
  }

  /// Leva o player ao estado pedido pelo widget.
  Future<void> _sync() async {
    if (!mounted) return;
    _retryTimer?.cancel();
    _errorCheck?.cancel();
    _recovering = false;
    _reportedDecoder = false;
    _lastPos = Duration.zero;
    _started = false;
    _liveSince = null;
    final url = widget.active ? widget.url : null;
    // Saindo de uma conexão que estava tocando, por pausa ou troca de IP: guarda a
    // última imagem para mostrar enquanto a próxima conexão abre.
    if (_openedUrl != null && url != _openedUrl && _phase == _Phase.live) {
      await _freezeFrame();
      if (!mounted) return;
    }
    if (url == null) {
      _openedUrl = null;
      await _player.stop();
      _setPhase(widget.url == null ? _Phase.searching : _Phase.connecting);
      return;
    }
    _openedUrl = url;
    _openedAt = DateTime.now();
    _sawAuthError = false;
    _lastProgress = DateTime.now();
    _setPhase(_Phase.connecting);
    await _player.open(Media(url), play: true);
  }

  /// Duas imagens 16:9 empilhadas dao um quadro mais alto que largo, perto de
  /// 8:9. Uma camera comum e mais larga que alta.
  bool get _dualLens {
    if (_videoW <= 0 || _videoH <= 0) return false;
    final ratio = _videoW / _videoH;
    return ratio > 0.6 && ratio < 1.0;
  }

  /// Durante a reconexão o player zera o tamanho. Manter o último evita que o
  /// layout das lentes pisque enquanto a imagem congelada está na tela.
  void _applyVideoSize() {
    if (_rawW <= 0 || _rawH <= 0) return;
    if (_rawW == _videoW && _rawH == _videoH) return;
    final wasDual = _dualLens;
    if (!mounted) return;
    setState(() {
      _videoW = _rawW;
      _videoH = _rawH;
    });
    if (_dualLens != wasDual) widget.onDualLens?.call(_dualLens);
  }

  /// Guarda o quadro que está na tela.
  ///
  /// Usa a imagem crua do mpv e monta direto na placa de vídeo. A versão em JPEG
  /// do media_kit comprime pixel a pixel em Dart e leva mais de 1 s na imagem
  /// principal, atrasando a reconexão.
  Future<void> _freezeFrame() async {
    final w = _videoW, h = _videoH;
    if (w <= 0 || h <= 0) return;
    final began = DateTime.now();
    try {
      final raw = await _player.screenshot(format: null).timeout(const Duration(seconds: 2));
      if (raw == null || !mounted) return;
      final stride = raw.length ~/ h;
      if (stride < w * 4) return;
      // O mpv entrega BGR com o quarto byte zerado: sem isto a imagem sai transparente.
      for (var i = 3; i < raw.length; i += 4) {
        raw[i] = 255;
      }
      final done = Completer<ui.Image>();
      ui.decodeImageFromPixels(raw, w, h, ui.PixelFormat.bgra8888, done.complete, rowBytes: stride);
      final image = await done.future;
      if (!mounted) {
        image.dispose();
        return;
      }
      if (_diag) {
        final took = DateTime.now().difference(began).inMilliseconds;
        debugPrint(
          '[diag ${widget.name}] imagem congelada ${w}x$h em $took ms, cores ${await _colorsMatch(raw, stride, image)}',
        );
      }
      final old = _frozen;
      setState(() {
        _frozen = image;
        _frozenAt = DateTime.now();
      });
      _disposeLater(old);
    } catch (_) {}
  }

  /// Diagnóstico: confere num pixel central se vermelho e azul não saíram trocados.
  static Future<String> _colorsMatch(Uint8List raw, int stride, ui.Image image) async {
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return 'sem leitura';
    final x = image.width ~/ 2, y = image.height ~/ 2;
    final src = y * stride + x * 4;
    final dst = (y * image.width + x) * 4;
    final ok =
        data.getUint8(dst) == raw[src + 2] &&
        data.getUint8(dst + 1) == raw[src + 1] &&
        data.getUint8(dst + 2) == raw[src];
    return ok ? 'conferem' : 'TROCADAS (origem BGR ${raw[src]},${raw[src + 1]},${raw[src + 2]})';
  }

  /// Libera a imagem depois do próximo quadro, quando nada mais a desenha.
  void _disposeLater(ui.Image? image) {
    if (image == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => image.dispose());
  }

  void _clearFrozen() {
    final old = _frozen;
    if (old == null) return;
    setState(() => _frozen = null);
    _disposeLater(old);
  }

  /// Tira a última imagem da frente quando o vídeo novo já está limpo.
  void _maybeThaw(DateTime now) {
    final since = _liveSince;
    if (_frozen == null || since == null) return;
    final playing = now.difference(since);
    final clean = playing >= _cleanFor && now.difference(_lastDecodeError) >= _cleanFor;
    if (clean || playing >= _frozenMaxLive) {
      if (_diag) {
        debugPrint(
          '[diag ${widget.name}] imagem congelada saiu após ${playing.inMilliseconds} ms de vídeo novo${clean ? '' : ' (limite, ainda com erros)'}',
        );
      }
      _clearFrozen();
    }
  }

  /// So conta como progresso quando o tempo do video realmente avanca. O
  /// player emite posicao zero ao abrir, antes de existir imagem.
  void _onPosition(Duration pos) {
    // Durante a recuperação, a conexão antiga já foi descartada, mesmo que ainda
    // mande avisos.
    if (_recovering) return;
    // Depois de reabrir, eventos atrasados da conexão anterior trazem posições do
    // vídeo antigo, maiores que o tempo desde a nova abertura. Num vídeo ao vivo a
    // posição nunca passa desse tempo.
    final opened = _openedAt;
    if (opened != null && pos > DateTime.now().difference(opened) + const Duration(seconds: 2)) return;
    if (_diag && pos + const Duration(seconds: 1) < _lastPos) {
      debugPrint(
        '[diag ${widget.name}] ${DateTime.now().toIso8601String().substring(11, 19)} posição voltou de ${_lastPos.inMilliseconds} para ${pos.inMilliseconds} ms',
      );
    }
    if (pos <= _lastPos) return;
    _lastPos = pos;
    _onProgress();
  }

  void _onProgress() {
    final now = DateTime.now();
    _lastProgress = now;
    if (_openedUrl == null) return;
    _failures = 0;
    if (!_started) {
      _started = true;
      _liveSince = now;
      final opened = _openedAt, failed = _failedAt;
      if (_diag && opened != null) {
        final sinceFail = failed == null ? '' : ', ${now.difference(failed).inMilliseconds} ms desde a falha';
        debugPrint(
          '[diag ${widget.name}] primeiro quadro ${now.difference(opened).inMilliseconds} ms após abrir$sinceFail',
        );
      }
      _failedAt = null;
    }
    if (_slow) setState(() => _slow = false);
    _setPhase(_Phase.live);
    _maybeThaw(now);
    _reportDecoder();
  }

  /// O mpv emite erros que nao interrompem o video, como "Cannot seek in this
  /// stream" ao abrir uma transmissao ao vivo. Um erro so conta como falha se a
  /// imagem nao avancar nos segundos seguintes.
  void _onPlayerError() {
    if (_openedUrl == null) return;
    final at = DateTime.now();
    _errorCheck?.cancel();
    _errorCheck = Timer(const Duration(seconds: 6), () {
      if (!_lastProgress.isAfter(at)) _onFailure('erro do player sem imagem nos 6 s seguintes');
    });
  }

  /// Diagnostico em modo debug: mostra se o video usa o decodificador do chip.
  Future<void> _reportDecoder() async {
    if (!_diag || _reportedDecoder) return;
    _reportedDecoder = true;
    final native = _player.platform;
    if (native is! NativePlayer) return;
    await Future<void>.delayed(const Duration(seconds: 4));
    if (!mounted) return;
    try {
      final hw = await native.getProperty('hwdec-current');
      final codec = await native.getProperty('video-codec');
      final w = await native.getProperty('width');
      final h = await native.getProperty('height');
      debugPrint('[player ${widget.name}] decodificador: ${hw.isEmpty ? "software" : hw} | $codec | ${w}x$h');
    } catch (_) {}
  }

  /// Diagnostico em modo debug: estado interno do player, a cada verificacao.
  Future<void> _diagState() async {
    final native = _player.platform;
    if (native is! NativePlayer || _openedUrl == null) return;
    final out = <String>[];
    for (final prop in const [
      'time-pos',
      'playback-time',
      'core-idle',
      'paused-for-cache',
      'hwdec-current',
      'video-codec',
      'estimated-vf-fps',
      'decoder-frame-drop-count',
      'frame-drop-count',
      'demuxer-cache-duration',
      'demuxer-cache-time',
      'untimed',
      'speed',
      'video-sync',
      'framedrop',
      'vo-configured',
    ]) {
      try {
        out.add('$prop=${await native.getProperty(prop)}');
      } catch (_) {
        out.add('$prop=?');
      }
    }
    debugPrint(
      '[diag ${widget.name}] ${DateTime.now().toIso8601String().substring(11, 23)} estado: ${out.join(' ')}',
    );
  }

  void _checkStall() {
    _ticks++;
    if (_diag && _ticks % 5 == 0) _diagState();
    final now = DateTime.now();
    final frozenAt = _frozenAt;
    if (_frozen != null && _phase != _Phase.live && frozenAt != null && now.difference(frozenAt) > _frozenMaxAge) {
      _clearFrozen();
    }
    if (_openedUrl == null || _recovering) return;
    final idle = now.difference(_lastProgress);
    final slow = _phase == _Phase.live && idle > _slowAfter;
    if (slow != _slow) setState(() => _slow = slow);
    final since = _liveSince;
    if (_debugDropEvery > 0 && since != null && now.difference(since).inSeconds >= _debugDropEvery) {
      _onFailure('teste: queda simulada');
      return;
    }
    final limit = _started ? _stallLive : _stallStart;
    if (idle > limit) {
      _onFailure(
        _started
            ? 'imagem parada há ${limit.inSeconds} s (última posição ${_lastPos.inMilliseconds} ms)'
            : 'sem o primeiro quadro em ${limit.inSeconds} s',
      );
    }
  }

  void _onFailure(String reason) {
    if (!mounted || _openedUrl == null || _recovering) return;
    _recovering = true;
    _failedAt ??= DateTime.now();
    if (_diag) {
      debugPrint('[diag ${widget.name}] ${DateTime.now().toIso8601String().substring(11, 23)} reconectando: $reason');
    }
    final wait = retryDelay(_failures);
    _failures++;
    final wasLive = _phase == _Phase.live;
    _setPhase(_sawAuthError ? _Phase.authError : _Phase.retrying);
    widget.onNeedRescan?.call();
    final began = DateTime.now();
    () async {
      // A imagem ainda está na tela: guarda antes de reabrir a conexão.
      if (wasLive) await _freezeFrame();
      if (!mounted || !_recovering) return;
      final left = wait - DateTime.now().difference(began);
      _retryTimer = Timer(left.isNegative ? Duration.zero : left, _sync);
    }();
  }

  @override
  void dispose() {
    if (widget.tileController?._state == this) widget.tileController?._state = null;
    _watchdog?.cancel();
    _retryTimer?.cancel();
    _errorCheck?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _frozen?.dispose();
    _player.dispose();
    super.dispose();
  }

  /// Aviso no centro, só quando não há imagem para mostrar.
  String? get _message {
    if (_phase == _Phase.authError) return 'Usuário ou senha recusados pela câmera.';
    if (_phase == _Phase.live || _frozen != null) return null;
    return switch (_phase) {
      _Phase.searching => 'Procurando a câmera na rede pelo MAC…',
      _Phase.connecting => 'Conectando…',
      _Phase.retrying => 'Sem imagem. Tentando de novo…',
      _ => null,
    };
  }

  /// A imagem na tela não é a atual: reconectando ou sem quadro novo.
  bool get _waiting => _frozen != null || _slow || _phase == _Phase.connecting || _phase == _Phase.retrying;

  Color get _dot {
    if (_phase == _Phase.authError) return const Color(0xFFF2555A);
    if (_phase == _Phase.retrying && !widget.online) return const Color(0xFFF2555A);
    return _waiting ? const Color(0xFFF5B942) : const Color(0xFF3ECF8E);
  }

  Widget _video(BoxFit fit) {
    final live = Video(
      controller: _controller,
      controls: NoVideoControls,
      fit: fit,
      fill: Colors.black,
      // O padrao do media_kit pausa em segundo plano e nao retoma sozinho.
      resumeUponEnteringForegroundMode: true,
    );
    final frozen = _frozen;
    if (frozen == null) return live;
    // Mesmo encaixe do vídeo: nos recortes de lente a imagem congelada acompanha.
    return Stack(
      fit: StackFit.expand,
      children: [
        live,
        RawImage(image: frozen, fit: fit, filterQuality: FilterQuality.medium),
      ],
    );
  }

  /// Uma das duas imagens: o mesmo video, com o dobro da altura da area e preso
  /// em cima ou embaixo, recortado para sobrar so a metade pedida.
  Widget _lens(bool top) {
    return Center(
      child: AspectRatio(
        aspectRatio: _videoW / (_videoH / 2),
        child: ClipRect(
          child: FractionallySizedBox(
            heightFactor: 2,
            alignment: top ? Alignment.topCenter : Alignment.bottomCenter,
            child: _video(BoxFit.fill),
          ),
        ),
      ),
    );
  }

  Widget _tappable(int lens, Widget child) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onLensTap == null ? null : () => widget.onLensTap!(lens),
      child: child,
    );
  }

  Widget _buildVideo() {
    final view = _dualLens ? widget.lensView : LensView.whole;
    switch (view) {
      case LensView.sideBySide:
        return Row(
          children: [
            Expanded(child: _tappable(0, _lens(true))),
            const SizedBox(width: 2),
            Expanded(child: _tappable(1, _lens(false))),
          ],
        );
      case LensView.top:
      case LensView.bottom:
        final lens = view == LensView.top ? 0 : 1;
        final single = _tappable(lens, _lens(lens == 0));
        return widget.zoomable ? InteractiveViewer(maxScale: 6, child: single) : single;
      case LensView.whole:
        Widget whole = _video(BoxFit.contain);
        if (_dualLens && widget.onLensTap != null) {
          // O quadro fica centralizado, entao as metades da area coincidem com as lentes.
          whole = Stack(
            fit: StackFit.expand,
            children: [
              whole,
              Column(
                children: [
                  Expanded(child: _tappable(0, const SizedBox.expand())),
                  Expanded(child: _tappable(1, const SizedBox.expand())),
                ],
              ),
            ],
          );
        }
        return widget.zoomable && !(_dualLens && widget.onLensTap != null)
            ? InteractiveViewer(maxScale: 6, child: whole)
            : whole;
    }
  }

  @override
  Widget build(BuildContext context) {
    final video = _buildVideo();
    final message = _message;
    return GestureDetector(
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: ColoredBox(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            video,
            if (message != null)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    message,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Color(0xFF8B95A5)),
                  ),
                ),
              ),
            Positioned(
              left: 10,
              top: 10,
              child: DecoratedBox(
                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(999)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 9,
                        height: 9,
                        decoration: BoxDecoration(color: _dot, shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 8),
                      Text(widget.name, style: const TextStyle(color: Colors.white, fontSize: 13)),
                      if (_waiting) ...[
                        const SizedBox(width: 8),
                        const SizedBox(
                          width: 10,
                          height: 10,
                          child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white70),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
