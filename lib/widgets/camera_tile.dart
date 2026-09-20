import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

enum _Phase { searching, connecting, live, retrying, authError }

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
  static const _stallLimit = Duration(seconds: 15);
  static const _backoff = [2, 4, 8, 15, 30];

  late final Player _player;
  late final VideoController _controller;
  final List<StreamSubscription<dynamic>> _subs = [];
  Timer? _watchdog;
  Timer? _retryTimer;
  Timer? _errorCheck;
  Duration _lastPos = Duration.zero;
  int _videoW = 0;
  int _videoH = 0;
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
    _controller = VideoController(_player);
    _subs.add(_player.stream.position.listen(_onPosition));
    _subs.add(_player.stream.width.listen((w) => _onVideoSize(w ?? 0, _videoH)));
    _subs.add(_player.stream.height.listen((h) => _onVideoSize(_videoW, h ?? 0)));
    _subs.add(_player.stream.error.listen((_) => _onPlayerError()));
    _subs.add(
      _player.stream.completed.listen((done) {
        if (done) _onFailure();
      }),
    );
    _subs.add(
      _player.stream.log.listen((log) {
        final t = log.text;
        if (t.contains('401') || t.contains('nauthorized')) {
          _sawAuthError = true;
        }
        if (kDebugMode) {
          debugPrint('[mpv ${widget.name}] ${log.level} ${log.prefix}: ${_maskSecrets(t.trim())}');
        }
      }),
    );
    _subs.add(
      _player.stream.error.listen((e) {
        if (kDebugMode) {
          debugPrint('[player ${widget.name}] erro: ${_maskSecrets(e)}');
        }
      }),
    );
    _watchdog = Timer.periodic(const Duration(seconds: 5), (_) => _checkStall());
    _configure().then((_) => _sync());
  }

  /// Ajustes do mpv para video ao vivo: sem cache, sem audio, RTSP por TCP.
  Future<void> _configure() async {
    final native = _player.platform;
    if (native is! NativePlayer) return;
    const props = {
      'rtsp-transport': 'tcp',
      'cache': 'no',
      'cache-on-disk': 'no',
      'cache-pause': 'no',
      'aid': 'no',
      'keep-open': 'no',
      'interpolation': 'no',
      'video-latency-hacks': 'yes',
      'demuxer-lavf-analyzeduration': '0.5',
      'network-timeout': '8',
    };
    for (final e in props.entries) {
      try {
        await native.setProperty(e.key, e.value);
      } catch (_) {}
    }
    try {
      await native.command(['change-list', 'demuxer-lavf-o', 'add', 'fflags=+nobuffer']);
    } catch (_) {}
  }

  @override
  void didUpdateWidget(CameraTile old) {
    super.didUpdateWidget(old);
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
    _reportedDecoder = false;
    _lastPos = Duration.zero;
    final url = widget.active ? widget.url : null;
    if (url == null) {
      _openedUrl = null;
      await _player.stop();
      _setPhase(widget.url == null ? _Phase.searching : _Phase.connecting);
      return;
    }
    _openedUrl = url;
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

  void _onVideoSize(int w, int h) {
    if (w == _videoW && h == _videoH) return;
    final wasDual = _dualLens;
    if (!mounted) return;
    setState(() {
      _videoW = w;
      _videoH = h;
    });
    if (_dualLens != wasDual) widget.onDualLens?.call(_dualLens);
  }

  /// So conta como progresso quando o tempo do video realmente avanca. O
  /// player emite posicao zero ao abrir, antes de existir imagem.
  void _onPosition(Duration pos) {
    if (pos <= _lastPos) return;
    _lastPos = pos;
    _onProgress();
  }

  void _onProgress() {
    _lastProgress = DateTime.now();
    if (_openedUrl != null) {
      _failures = 0;
      _setPhase(_Phase.live);
      _reportDecoder();
    }
  }

  /// O mpv emite erros que nao interrompem o video, como "Cannot seek in this
  /// stream" ao abrir uma transmissao ao vivo. Um erro so conta como falha se a
  /// imagem nao avancar nos segundos seguintes.
  void _onPlayerError() {
    if (_openedUrl == null) return;
    final at = DateTime.now();
    _errorCheck?.cancel();
    _errorCheck = Timer(const Duration(seconds: 6), () {
      if (!_lastProgress.isAfter(at)) _onFailure();
    });
  }

  /// Diagnostico em modo debug: mostra se o video usa o decodificador do chip.
  Future<void> _reportDecoder() async {
    if (!kDebugMode || _reportedDecoder) return;
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

  void _checkStall() {
    if (_openedUrl == null || _retryTimer?.isActive == true) return;
    if (DateTime.now().difference(_lastProgress) > _stallLimit) _onFailure();
  }

  void _onFailure() {
    if (!mounted || _openedUrl == null || _retryTimer?.isActive == true) return;
    final wait = _backoff[_failures.clamp(0, _backoff.length - 1)];
    _failures++;
    _setPhase(_sawAuthError ? _Phase.authError : _Phase.retrying);
    widget.onNeedRescan?.call();
    _retryTimer = Timer(Duration(seconds: wait), _sync);
  }

  @override
  void dispose() {
    _watchdog?.cancel();
    _retryTimer?.cancel();
    _errorCheck?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    super.dispose();
  }

  String? get _message => switch (_phase) {
    _Phase.searching => 'Procurando a câmera na rede pelo MAC…',
    _Phase.connecting => 'Conectando…',
    _Phase.retrying => 'Sem imagem. Tentando de novo…',
    _Phase.authError => 'Usuário ou senha recusados pela câmera.',
    _Phase.live => null,
  };

  Color get _dot => switch (_phase) {
    _Phase.live => const Color(0xFF3ECF8E),
    _Phase.authError => const Color(0xFFF2555A),
    _Phase.retrying => widget.online ? const Color(0xFFF5B942) : const Color(0xFFF2555A),
    _ => const Color(0xFFF5B942),
  };

  Video _video(BoxFit fit) => Video(
    controller: _controller,
    controls: NoVideoControls,
    fit: fit,
    fill: Colors.black,
    // O padrao do media_kit pausa em segundo plano e nao retoma sozinho.
    resumeUponEnteringForegroundMode: true,
  );

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
