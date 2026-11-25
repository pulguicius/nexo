package org.nexo.bridge

/**
 * La red que usa el móvil (protocolo 1.5, `net.status` y el tema `net`): la parte que NO es Android, para poder probarla en la JVM
 * (NetLogicTest). NetHandler.kt le pasa lo que Android cuenta de la red por defecto y arma el JSON.
 */
object NetLogic {

    /** Lo que importa de un `NetworkCapabilities`, como valores simples. */
    data class Caps(
        val wifi: Boolean = false,
        val cellular: Boolean = false,
        val ethernet: Boolean = false,
        val bluetooth: Boolean = false,
        /** El transporte VPN, o que falte la capacidad NOT_VPN. */
        val vpn: Boolean = false,
        /** Android cree que esa red lleva a internet (NET_CAPABILITY_INTERNET). */
        val internet: Boolean = false,
        /** Android comprobó que de verdad sale a internet (NET_CAPABILITY_VALIDATED). */
        val validated: Boolean = false,
        /** Tarifa plana: NET_CAPABILITY_NOT_METERED. Lo contrario es una red «de pago» (datos móviles, o un WiFi marcado así). */
        val notMetered: Boolean = false,
        /** Hay un portal cautivo que pide iniciar sesión (NET_CAPABILITY_CAPTIVE_PORTAL). */
        val captive: Boolean = false,
    )

    /**
     * Por dónde sale el móvil: "wifi", "ethernet", "cellular", "bluetooth", "other" (una VPN sin red física conocida u otra cosa)
     * o "none" (sin red). Con una VPN encima de una red, cuenta la red física: la VPN se avisa aparte (`vpn`).
     */
    fun typeOf(c: Caps?): String = when {
        c == null -> "none"
        c.wifi -> "wifi"
        c.ethernet -> "ethernet"
        c.cellular -> "cellular"
        c.bluetooth -> "bluetooth"
        else -> "other"
    }

    /** ¿Es una red «de pago» (por la que conviene no bajar cosas grandes)? Sin red, no. */
    fun metered(c: Caps?): Boolean = c != null && !c.notMetered
}
