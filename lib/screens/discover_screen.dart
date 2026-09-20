import 'package:flutter/material.dart';

import '../services/app_controller.dart';
import '../services/discovery.dart';
import 'camera_form_screen.dart';

/// Caminho principal para adicionar uma camera: procura na rede Wi-Fi e mostra
/// o que respondeu. Ninguem precisa saber MAC nem IP.
class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  List<FoundCamera>? _found;
  bool _searching = false;

  AppController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _search();
  }

  Future<void> _search() async {
    if (_searching) return;
    setState(() => _searching = true);
    // Duas varreduras seguidas: respostas se perdem no Wi-Fi, e a segunda
    // costuma trazer quem faltou na primeira.
    final byKey = <String, FoundCamera>{};
    for (var i = 0; i < 2; i++) {
      for (final f in await c.discoverAll()) {
        final key = f.serial.isEmpty ? f.primary.mac : f.serial;
        final old = byKey[key];
        if (old == null || f.interfaces.length > old.interfaces.length) byKey[key] = f;
      }
      if (!mounted) return;
      setState(() => _found = byKey.values.toList());
    }
    setState(() => _searching = false);
  }

  Future<void> _open({FoundCamera? from}) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => CameraFormScreen(controller: c, found: from),
      ),
    );
    if (!mounted) return;
    if (saved == true) {
      Navigator.of(context).pop();
    } else {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final found = _found;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Adicionar câmera'),
        actions: [
          IconButton(
            tooltip: 'Procurar de novo',
            onPressed: _searching ? null : _search,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: c,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _searching ? 'Procurando câmeras nesta rede Wi-Fi…' : 'Câmeras encontradas nesta rede Wi-Fi',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (_searching) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              ],
            ),
            const SizedBox(height: 8),
            if (found != null && found.isEmpty && !_searching)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  'Nenhuma câmera respondeu. Confira se este aparelho está no mesmo Wi-Fi das câmeras e toque em '
                  'procurar de novo. A busca encontra câmeras Xiongmai, as dos apps iCSee e XMEye.',
                  style: TextStyle(color: muted),
                ),
              ),
            for (final f in found ?? const <FoundCamera>[])
              _FoundTile(
                found: f,
                controller: c,
                onAdd: () => _open(from: f),
              ),
            const SizedBox(height: 24),
            Center(
              child: TextButton.icon(
                onPressed: () => _open(),
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: const Text('Informar o MAC manualmente'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FoundTile extends StatelessWidget {
  const _FoundTile({required this.found, required this.controller, required this.onAdd});

  final FoundCamera found;
  final AppController controller;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final d = found.primary;
    final registered = controller.registeredFor(found);
    final extra = found.interfaces.length > 1 ? ', ${found.interfaces.length} endereços na rede' : '';
    return Card(
      child: ListTile(
        leading: const Icon(Icons.videocam_outlined),
        title: Text(d.hostname.isEmpty ? 'Câmera' : d.hostname),
        subtitle: Text(
          'IP ${d.ip}$extra\nsérie ${d.serial.isEmpty ? "desconhecida" : d.serial}',
          style: const TextStyle(fontSize: 12.5, height: 1.5),
        ),
        isThreeLine: true,
        trailing: registered != null
            ? Text(
                'já cadastrada\n${registered.name}',
                textAlign: TextAlign.right,
                style: TextStyle(color: muted, fontSize: 12),
              )
            : FilledButton(onPressed: onAdd, child: const Text('Adicionar')),
        onTap: registered == null ? onAdd : null,
      ),
    );
  }
}
