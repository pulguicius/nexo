package org.nexo.bridge

import android.app.Activity
import android.os.Bundle

/**
 * Android la abre cuando se conecta un dispositivo de res/xml/usb_device_filter.xml y el usuario aceptó «abrir Nexo con este
 * dispositivo». Solo existe para que Android ofrezca recordar el permiso USB; no muestra nada y se cierra al instante.
 * Lo que hace Nexo con el dispositivo lo piden los clientes (`nexo usb …`) por el puente.
 */
class UsbAttachedActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        finish()
    }
}
