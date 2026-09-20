import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  // O app e um mural fixo: a tela nunca apaga enquanto ele estiver aberto.
  // Equivale ao FLAG_KEEP_SCREEN_ON usado no Android.
  override func sceneDidBecomeActive(_ scene: UIScene) {
    super.sceneDidBecomeActive(scene)
    UIApplication.shared.isIdleTimerDisabled = true
  }
}
