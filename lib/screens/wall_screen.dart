import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_controller.dart';
import '../widgets/camera_tile.dart';
import 'camera_view_screen.dart';
import 'discover_screen.dart';
import 'settings_screen.dart';

/// Apenas para desenvolvimento: `--dart-define=CAMWALL_DEBUG_URL=rtsp://...`
/// acrescenta um video de teste ao mural. No emulador a descoberta por
/// broadcast nao atravessa a rede virtual, entao este e o jeito de validar o player.
const String _debugUrl = String.fromEnvironment('CAMWALL_DEBUG_URL');

/// Apenas para desenvolvimento: `--dart-define=CAMWALL_DEBUG_OPEN=Portao` abre essa
/// câmera em tela cheia ao iniciar, para medir a imagem principal sem tocar na tela.
const String _debugOpen = String.fromEnvironment('CAMWALL_DEBUG_OPEN');

/// Tela principal: todas as cameras dividindo a tela inteira.
class WallScreen extends StatefulWidget {
  const WallScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<WallScreen> createState() => _WallScreenState();
}

class _WallScreenState extends State<WallScreen> with WidgetsBindingObserver {
  /// false enquanto outra tela esta por cima ou o app esta em segundo plano.
  bool _active = true;
  bool _debugOpened = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final resumed = state == AppLifecycleState.resumed;
    if (resumed) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      widget.controller.start();
    } else if (state == AppLifecycleState.paused) {
      widget.controller.stop();
    }
    if (mounted && state != AppLifecycleState.inactive) {
      setState(() => _active = resumed);
    }
  }

  Future<void> _push(Widget screen) async {
    setState(() => _active = false);
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
    if (!mounted) return;
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    setState(() => _active = true);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return Scaffold(
      backgroundColor: Colors.black,
      body: ListenableBuilder(
        listenable: c,
        builder: (context, _) {
          if (!c.loaded) {
            return const Center(child: CircularProgressIndicator());
          }
          final cams = c.cameras;
          if (_debugOpen.isNotEmpty && !_debugOpened) {
            final target = cams.where((cam) => cam.name == _debugOpen);
            if (target.isNotEmpty) {
              _debugOpened = true;
              final id = target.first.id;
              WidgetsBinding.instance.addPostFrameCallback((_) => _push(CameraViewScreen(controller: c, cameraId: id)));
            }
          }
          final tiles = <Widget>[
            for (final cam in cams)
              CameraTile(
                key: ValueKey(cam.id),
                name: cam.name,
                url: c.urlFor(cam, mainStream: c.gridMainStream),
                online: c.isOnline(cam),
                active: _active,
                onNeedRescan: c.rescan,
                onTap: () => _push(CameraViewScreen(controller: c, cameraId: cam.id)),
              ),
            if (_debugUrl.isNotEmpty)
              CameraTile(key: const ValueKey('debug'), name: 'Teste', url: _debugUrl, online: true, active: _active),
          ];
          return SafeArea(
            child: Stack(
              children: [
                if (tiles.isEmpty) _Empty(onAdd: () => _push(DiscoverScreen(controller: c))) else _Grid(tiles: tiles),
                Positioned(
                  right: 8,
                  top: 8,
                  child: IconButton.filledTonal(
                    tooltip: 'Configurações',
                    style: IconButton.styleFrom(backgroundColor: Colors.black45),
                    icon: const Icon(Icons.settings, color: Colors.white70),
                    onPressed: () => _push(SettingsScreen(controller: c)),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Divide a tela inteira entre os videos, sem rolagem.
class _Grid extends StatelessWidget {
  const _Grid({required this.tiles});

  final List<Widget> tiles;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final n = tiles.length;
        final landscape = box.maxWidth >= box.maxHeight;
        var cols = 1;
        while (cols * cols < n) {
          cols++;
        }
        if (!landscape) cols = n <= 2 ? 1 : (cols > 2 ? cols - 1 : cols);
        if (landscape && n == 2) cols = 2;
        final rows = (n / cols).ceil();
        const gap = 2.0;
        return Column(
          children: [
            for (var r = 0; r < rows; r++) ...[
              if (r > 0) const SizedBox(height: gap),
              Expanded(
                child: Row(
                  children: [
                    for (var col = 0; col < cols; col++) ...[
                      if (col > 0) const SizedBox(width: gap),
                      Expanded(child: r * cols + col < n ? tiles[r * cols + col] : const SizedBox.shrink()),
                    ],
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.videocam_off_outlined, size: 56, color: Color(0xFF8B95A5)),
          const SizedBox(height: 12),
          const Text('Nenhuma câmera cadastrada.', style: TextStyle(color: Color(0xFF8B95A5))),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.wifi_find_outlined),
            label: const Text('Procurar câmeras na rede'),
          ),
        ],
      ),
    );
  }
}
