import 'package:flutter/material.dart';

import '../models/camera.dart';
import '../services/app_controller.dart';
import 'camera_form_screen.dart';
import 'discover_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  AppController get c => widget.controller;

  Future<void> _add() =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => DiscoverScreen(controller: c)));

  Future<void> _edit(Camera camera) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => CameraFormScreen(controller: c, camera: camera),
    ),
  );

  Future<void> _confirmRemove(Camera cam) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remover câmera'),
        content: Text('Remover "${cam.name}" do app?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remover')),
        ],
      ),
    );
    if (ok == true) await c.remove(cam.id);
  }

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Scaffold(
      appBar: AppBar(title: const Text('Configurações')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.add),
        label: const Text('Adicionar câmera'),
      ),
      body: ListenableBuilder(
        listenable: c,
        builder: (context, _) {
          final cams = c.cameras;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
            children: [
              _SectionTitle(
                'Câmeras cadastradas',
                trailing: TextButton.icon(
                  onPressed: c.isScanning ? null : c.rescan,
                  icon: c.isScanning
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.refresh, size: 18),
                  label: const Text('Buscar IPs'),
                ),
              ),
              Text(
                'O IP é descoberto pelo MAC e atualizado sozinho a cada ${AppController.scanInterval.inSeconds} segundos.',
                style: TextStyle(color: muted, fontSize: 13),
              ),
              const SizedBox(height: 8),
              if (cams.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text('Nenhuma câmera cadastrada ainda.', style: TextStyle(color: muted)),
                ),
              for (final cam in cams)
                Card(
                  child: ListTile(
                    leading: Icon(
                      Icons.circle,
                      size: 12,
                      color: c.isOnline(cam) ? const Color(0xFF3ECF8E) : const Color(0xFFF2555A),
                    ),
                    title: Text(cam.name),
                    subtitle: Text(
                      '${cam.mac}\n'
                      '${cam.lastIp.isEmpty ? "IP ainda não encontrado" : "IP ${cam.lastIp}${c.isOnline(cam) ? "" : ", último conhecido"}"}\n'
                      'usuário ${cam.user.isEmpty ? "vazio" : cam.user}, ${c.hasPassword(cam) ? "senha definida" : "sem senha"}',
                      style: const TextStyle(fontSize: 12.5, height: 1.5),
                    ),
                    isThreeLine: true,
                    onTap: () => _edit(cam),
                    trailing: IconButton(
                      tooltip: 'Remover',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => _confirmRemove(cam),
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Imagem principal no mural'),
                subtitle: const Text(
                  'Desligado usa a imagem secundária, mais leve. Ao tocar numa câmera ela sempre abre na principal.',
                ),
                value: c.gridMainStream,
                onChanged: c.setGridMainStream,
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text, {this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Row(
        children: [
          Expanded(child: Text(text, style: Theme.of(context).textTheme.titleMedium)),
          ?trailing,
        ],
      ),
    );
  }
}
