import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/onvif_ptz.dart';

/// Direcional de movimento da camera: segurar move, soltar para.
class PtzPad extends StatefulWidget {
  const PtzPad({super.key, required this.ptz, required this.cameraName});

  final OnvifPtz ptz;
  final String cameraName;

  @override
  State<PtzPad> createState() => _PtzPadState();
}

class _PtzPadState extends State<PtzPad> {
  static const _speed = 0.5;

  /// Se o dedo ficar preso ou o "soltar" se perder, a camera para sozinha.
  static const _maxHold = Duration(seconds: 8);

  /// Fila de comandos. O "parar" so sai depois que o "mover" terminou: sem
  /// isso, um toque rapido mandaria parar antes de mover e a camera ficaria
  /// girando sem ninguem para interromper.
  Future<void> _queue = Future.value();
  Timer? _safety;
  int? _active;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Prepara ao abrir, para o primeiro toque responder na hora e para um
    // problema de senha aparecer antes de qualquer movimento.
    _run(() => widget.ptz.prepare(), label: 'preparar');
  }

  @override
  void dispose() {
    _safety?.cancel();
    if (_active != null) _queue = _queue.then((_) => widget.ptz.stop()).catchError((Object _) {});
    super.dispose();
  }

  void _run(Future<void> Function() op, {required String label}) {
    _queue = _queue.then((_) async {
      if (mounted) setState(() => _busy = true);
      try {
        await op();
        if (kDebugMode) debugPrint('[ptz ${widget.cameraName}] $label: ok');
        if (mounted && _error != null) setState(() => _error = null);
      } catch (e) {
        if (kDebugMode) debugPrint('[ptz ${widget.cameraName}] $label: $e');
        if (mounted) setState(() => _error = e is PtzException ? e.message : 'Falha no comando.');
      } finally {
        if (mounted) setState(() => _busy = false);
      }
    });
  }

  void _press(int index, double x, double y) {
    if (_active != null) return;
    setState(() => _active = index);
    _run(() => widget.ptz.move(x * _speed, y * _speed), label: 'mover');
    _safety?.cancel();
    _safety = Timer(_maxHold, _release);
  }

  void _release() {
    if (_active == null) return;
    _safety?.cancel();
    if (mounted) setState(() => _active = null);
    _run(() => widget.ptz.stop(), label: 'parar');
  }

  Widget _arrow(int index, IconData icon, double x, double y, Alignment alignment) {
    final pressed = _active == index;
    return Align(
      alignment: alignment,
      child: Listener(
        onPointerDown: (_) => _press(index, x, y),
        onPointerUp: (_) => _release(),
        onPointerCancel: (_) => _release(),
        child: Container(
          width: 60,
          height: 60,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: pressed ? const Color(0xFF4C9AFF) : Colors.white.withValues(alpha: 0.16),
          ),
          child: Icon(icon, color: Colors.white, size: 34),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (_error != null)
          Container(
            constraints: const BoxConstraints(maxWidth: 260),
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(8)),
            child: Text(_error!, style: const TextStyle(color: Color(0xFFFFD6A0), fontSize: 12.5)),
          ),
        Container(
          width: 190,
          height: 190,
          decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.black.withValues(alpha: 0.35)),
          child: Stack(
            children: [
              _arrow(0, Icons.keyboard_arrow_up, 0, 1, Alignment.topCenter),
              _arrow(1, Icons.keyboard_arrow_down, 0, -1, Alignment.bottomCenter),
              _arrow(2, Icons.keyboard_arrow_left, -1, 0, Alignment.centerLeft),
              _arrow(3, Icons.keyboard_arrow_right, 1, 0, Alignment.centerRight),
              if (_busy && _active == null)
                const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))),
            ],
          ),
        ),
      ],
    );
  }
}
