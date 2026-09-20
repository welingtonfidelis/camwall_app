package com.welington.camwall_app

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // O app e um mural fixo: a tela nunca apaga enquanto ele estiver aberto.
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    override fun onResume() {
        super.onResume()
        // Sem esta trava, muitos aparelhos descartam pacotes de broadcast no Wi-Fi,
        // e parte das respostas de descoberta das cameras chega por broadcast.
        if (multicastLock == null) {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            multicastLock = wifi.createMulticastLock("camwall-discovery").apply {
                setReferenceCounted(false)
                acquire()
            }
        }
    }

    override fun onPause() {
        multicastLock?.let { if (it.isHeld) it.release() }
        multicastLock = null
        super.onPause()
    }
}
