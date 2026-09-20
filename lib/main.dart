import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import 'screens/wall_screen.dart';
import 'services/app_controller.dart';

/// Apenas para desenvolvimento: `--dart-define=CAMWALL_DEBUG_LANDSCAPE=true`
/// prende o app deitado, para testar esse layout num aparelho com a rotacao travada.
const bool _debugLandscape = bool.fromEnvironment('CAMWALL_DEBUG_LANDSCAPE');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (_debugLandscape) {
    SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
  }
  MediaKit.ensureInitialized();
  final controller = AppController()..load();
  runApp(CamwallApp(controller: controller));
}

class CamwallApp extends StatelessWidget {
  const CamwallApp({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Câmeras',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF4C9AFF), brightness: Brightness.dark),
        scaffoldBackgroundColor: const Color(0xFF0E1116),
        inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
      ),
      home: WallScreen(controller: controller),
    );
  }
}
