import 'package:flutter/material.dart';
import 'package:gal/gal.dart';

import '../services/app_controller.dart';
import '../services/onvif_ptz.dart';
import '../widgets/camera_tile.dart';
import '../widgets/ptz_pad.dart';

/// Uma camera em tela cheia, com a imagem principal.
///
/// Em cameras de duas lentes: com a tela deitada as duas imagens ficam lado a
/// lado, e com a tela em pe ficam empilhadas como a camera envia. Tocar numa
/// imagem abre so ela, com zoom por pinca. Tocar de novo, ou voltar, retorna.
class CameraViewScreen extends StatefulWidget {
  const CameraViewScreen({super.key, required this.controller, required this.cameraId});

  final AppController controller;
  final String cameraId;

  @override
  State<CameraViewScreen> createState() => _CameraViewScreenState();
}

class _CameraViewScreenState extends State<CameraViewScreen> {
  final _tile = CameraTileController();

  bool _dual = false;

  /// Lente aberta sozinha: 0 em cima, 1 embaixo, null mostra as duas.
  int? _lens;

  /// Direcional de movimento visivel.
  bool _showPtz = false;
  OnvifPtz? _ptz;
  String _ptzIp = '';

  /// Som da camera. Sempre comeca desligado.
  bool _muted = true;
  bool _saving = false;

  void _back() {
    if (_lens != null) {
      setState(() => _lens = null);
    } else {
      Navigator.of(context).pop();
    }
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 2)));
  }

  Future<void> _savePhoto(String cameraName) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final bytes = await _tile.capture();
      if (bytes == null) {
        _say('Espere a imagem aparecer para tirar a foto.');
        return;
      }
      if (!await Gal.hasAccess()) await Gal.requestAccess();
      await Gal.putImageBytes(bytes, name: _photoName(cameraName));
      _say('Foto salva na galeria.');
    } on GalException catch (e) {
      _say(
        e.type == GalExceptionType.accessDenied
            ? 'Permita o acesso às fotos para salvar.'
            : 'Não foi possível salvar a foto.',
      );
    } catch (_) {
      _say('Não foi possível salvar a foto.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Nome do arquivo: camwall-Portao-2026-09-20-14h32m07.
  static String _photoName(String cameraName) {
    final safe = cameraName.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-').replaceAll(RegExp(r'^-|-$'), '');
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp = '${n.year}-${two(n.month)}-${two(n.day)}-${two(n.hour)}h${two(n.minute)}m${two(n.second)}';
    return 'camwall-${safe.isEmpty ? "camera" : safe}-$stamp';
  }

  Widget _button({required String tooltip, required IconData icon, required VoidCallback? onPressed, bool on = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: IconButton.filledTonal(
        tooltip: tooltip,
        style: IconButton.styleFrom(backgroundColor: on ? const Color(0xFF4C9AFF) : Colors.black45),
        icon: Icon(icon, color: on ? Colors.black : Colors.white70),
        onPressed: onPressed,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return PopScope(
      canPop: _lens == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _lens = null);
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            final matches = controller.cameras.where((c) => c.id == widget.cameraId);
            if (matches.isEmpty) return const SizedBox.shrink();
            final cam = matches.first;
            final landscape = MediaQuery.orientationOf(context) == Orientation.landscape;
            // Se o IP mudar com o direcional aberto, o cliente e refeito no IP novo.
            if (_showPtz && (_ptz == null || _ptzIp != cam.lastIp)) {
              _ptz = controller.ptzFor(cam);
              _ptzIp = cam.lastIp;
            }
            final view = switch (_lens) {
              0 => LensView.top,
              1 => LensView.bottom,
              _ => landscape ? LensView.sideBySide : LensView.whole,
            };
            return SafeArea(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CameraTile(
                    name: cam.name,
                    url: controller.urlFor(cam, mainStream: true),
                    online: controller.isOnline(cam),
                    zoomable: true,
                    lensView: view,
                    muted: _muted,
                    tileController: _tile,
                    onDualLens: (dual) => setState(() => _dual = dual),
                    onLensTap: (lens) => setState(() => _lens = _lens == null ? lens : null),
                    onNeedRescan: controller.rescan,
                  ),
                  if (_showPtz && _ptz != null)
                    Positioned(
                      right: 16,
                      bottom: 16,
                      child: PtzPad(key: ValueKey(_ptzIp), ptz: _ptz!, cameraName: cam.name),
                    ),
                  Positioned(
                    right: 8,
                    top: 8,
                    child: Column(
                      children: [
                        _button(
                          tooltip: _lens != null ? 'Ver as duas imagens' : 'Voltar ao mural',
                          icon: _lens != null && _dual ? Icons.splitscreen : Icons.close,
                          onPressed: _back,
                        ),
                        _button(
                          tooltip: _muted ? 'Ouvir o som da câmera' : 'Desligar o som',
                          icon: _muted ? Icons.volume_off : Icons.volume_up,
                          on: !_muted,
                          onPressed: () => setState(() => _muted = !_muted),
                        ),
                        _button(
                          tooltip: 'Salvar uma foto na galeria',
                          icon: _saving ? Icons.hourglass_empty : Icons.photo_camera_outlined,
                          onPressed: _saving ? null : () => _savePhoto(cam.name),
                        ),
                        _button(
                          tooltip: _showPtz ? 'Esconder o controle de movimento' : 'Mover a câmera',
                          icon: Icons.control_camera,
                          on: _showPtz,
                          onPressed: () => setState(() => _showPtz = !_showPtz),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
