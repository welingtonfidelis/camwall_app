import 'package:flutter/material.dart';

import '../models/camera.dart';
import '../services/app_controller.dart';
import '../services/discovery.dart';

/// Cadastro e edicao de uma camera: nome, MAC, usuario e senha.
class CameraFormScreen extends StatefulWidget {
  const CameraFormScreen({super.key, required this.controller, this.camera, this.found});

  final AppController controller;
  final Camera? camera;

  /// Camera escolhida na busca da rede. Com ela o MAC ja e conhecido e o campo
  /// de MAC nem aparece.
  final FoundCamera? found;

  @override
  State<CameraFormScreen> createState() => _CameraFormScreenState();
}

class _CameraFormScreenState extends State<CameraFormScreen> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name, _mac, _user, _password, _template;
  bool _showPassword = false;
  bool _clearPassword = false;
  bool _saving = false;
  late bool _invertPan = widget.camera?.invertPan ?? true;
  late bool _invertTilt = widget.camera?.invertTilt ?? false;

  bool get _editing => widget.camera != null;
  bool get _hadPassword => _editing && widget.controller.hasPassword(widget.camera!);

  @override
  void initState() {
    super.initState();
    final cam = widget.camera;
    final pre = widget.found?.primary;
    _name = TextEditingController(text: cam?.name ?? pre?.hostname ?? '');
    _mac = TextEditingController(text: cam?.mac ?? pre?.mac ?? '');
    _user = TextEditingController(text: cam?.user ?? 'admin');
    _password = TextEditingController();
    _template = TextEditingController(text: cam?.template ?? kDefaultTemplate);
  }

  @override
  void dispose() {
    for (final t in [_name, _mac, _user, _password, _template]) {
      t.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final error = widget.controller.validate(name: _name.text, mac: _mac.text, ignoreId: widget.camera?.id);
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    setState(() => _saving = true);
    // Ao editar, senha em branco significa manter a atual.
    String? password = _password.text;
    if (_editing && password.isEmpty && !_clearPassword) password = null;
    await widget.controller.save(
      id: widget.camera?.id,
      name: _name.text,
      mac: _mac.text,
      user: _user.text,
      template: _template.text,
      password: password,
      knownIp: widget.found?.primary.ip ?? '',
      serial: widget.found?.serial,
      invertPan: _invertPan,
      invertTilt: _invertTilt,
    );
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_editing ? 'Editar câmera' : 'Adicionar câmera')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Nome', hintText: 'Garagem'),
              textCapitalization: TextCapitalization.sentences,
              maxLength: 60,
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Informe um nome.' : null,
            ),
            const SizedBox(height: 8),
            if (widget.found != null)
              Card(
                margin: EdgeInsets.zero,
                child: ListTile(
                  leading: const Icon(Icons.wifi_find_outlined),
                  title: Text('Encontrada em ${widget.found!.primary.ip}'),
                  subtitle: Text(
                    'série ${widget.found!.serial.isEmpty ? "desconhecida" : widget.found!.serial}\n'
                    'O app acompanha esta câmera sozinho, mesmo que o IP mude.',
                    style: const TextStyle(fontSize: 12.5, height: 1.5),
                  ),
                  isThreeLine: true,
                ),
              )
            else
              TextFormField(
                controller: _mac,
                decoration: const InputDecoration(labelText: 'MAC', hintText: '02:1a:2b:ce:41:f5'),
                autocorrect: false,
                enableSuggestions: false,
                validator: (v) => normalizeMac(v ?? '') == null ? 'MAC inválido. Exemplo: 02:1a:2b:ce:41:f5' : null,
              ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _user,
              decoration: const InputDecoration(labelText: 'Usuário', hintText: 'admin'),
              autocorrect: false,
              enableSuggestions: false,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _password,
              obscureText: !_showPassword,
              autocorrect: false,
              enableSuggestions: false,
              enabled: !_clearPassword,
              decoration: InputDecoration(
                labelText: 'Senha',
                helperText: _hadPassword
                    ? 'Deixe em branco para manter a senha atual.'
                    : 'Senha do dispositivo, a mesma definida no app do fabricante.',
                suffixIcon: IconButton(
                  icon: Icon(_showPassword ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _showPassword = !_showPassword),
                ),
              ),
            ),
            if (_hadPassword)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('Remover a senha salva'),
                value: _clearPassword,
                onChanged: (v) => setState(() {
                  _clearPassword = v ?? false;
                  if (_clearPassword) _password.clear();
                }),
              ),
            const SizedBox(height: 8),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('Avançado: movimento e modelo de URL'),
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Inverter esquerda e direita'),
                  subtitle: const Text('Ligado é o correto para as câmeras Xiongmai.'),
                  value: _invertPan,
                  onChanged: (v) => setState(() => _invertPan = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Inverter cima e baixo'),
                  subtitle: const Text('Use se a câmera estiver montada de cabeça para baixo.'),
                  value: _invertTilt,
                  onChanged: (v) => setState(() => _invertTilt = v),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _template,
                  autocorrect: false,
                  enableSuggestions: false,
                  maxLines: 3,
                  minLines: 2,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                  decoration: const InputDecoration(
                    helperText: 'Marcadores: {ip} {user} {password} {stream}',
                    helperMaxLines: 2,
                  ),
                  validator: (v) => validateTemplate(v ?? ''),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => setState(() => _template.text = kDefaultTemplate),
                    child: const Text('Restaurar o modelo padrão'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(_editing ? 'Salvar' : 'Adicionar'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
