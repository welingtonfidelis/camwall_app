import 'package:flutter/material.dart';

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
  bool _dual = false;

  /// Lente aberta sozinha: 0 em cima, 1 embaixo, null mostra as duas.
  int? _lens;

  /// Direcional de movimento visivel.
  bool _showPtz = false;
  OnvifPtz? _ptz;
  String _ptzIp = '';

  void _back() {
    if (_lens != null) {
      setState(() => _lens = null);
    } else {
      Navigator.of(context).pop();
    }
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
                    onDualLens: (dual) => setState(() => _dual = dual),
                    onLensTap: (lens) => setState(() => _lens = _lens == null ? lens : null),
                    onNeedRescan: controller.rescan,
                  ),
                  Positioned(
                    right: 8,
                    top: 64,
                    child: IconButton.filledTonal(
                      tooltip: _showPtz ? 'Esconder o controle de movimento' : 'Mover a câmera',
                      style: IconButton.styleFrom(backgroundColor: _showPtz ? const Color(0xFF4C9AFF) : Colors.black45),
                      icon: Icon(Icons.control_camera, color: _showPtz ? Colors.black : Colors.white70),
                      onPressed: () => setState(() => _showPtz = !_showPtz),
                    ),
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
                    child: IconButton.filledTonal(
                      tooltip: _lens != null ? 'Ver as duas imagens' : 'Voltar ao mural',
                      style: IconButton.styleFrom(backgroundColor: Colors.black45),
                      icon: Icon(_lens != null && _dual ? Icons.splitscreen : Icons.close, color: Colors.white70),
                      onPressed: _back,
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
