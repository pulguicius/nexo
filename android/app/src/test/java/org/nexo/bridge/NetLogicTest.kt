package org.nexo.bridge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pruebas en JVM (sin Android) de NetLogic.kt: cómo se resume la red por defecto del móvil (`net.status`, protocolo 1.5).
 * Lo que NO prueba: que Android conteste lo que se espera a ConnectivityManager (NetHandler.kt), que solo se ha comprobado que compila.
 */
class NetLogicTest {

    @Test
    fun withoutNetworkItIsNone() {
        assertEquals("none", NetLogic.typeOf(null))
        assertFalse("sin red no hay red de pago", NetLogic.metered(null))
    }

    @Test
    fun eachTransportHasItsName() {
        assertEquals("wifi", NetLogic.typeOf(NetLogic.Caps(wifi = true)))
        assertEquals("ethernet", NetLogic.typeOf(NetLogic.Caps(ethernet = true)))
        assertEquals("cellular", NetLogic.typeOf(NetLogic.Caps(cellular = true)))
        assertEquals("bluetooth", NetLogic.typeOf(NetLogic.Caps(bluetooth = true)))
    }

    @Test
    fun aNetworkWithoutKnownTransportIsOther() {
        assertEquals("other", NetLogic.typeOf(NetLogic.Caps()))
        assertEquals("other", NetLogic.typeOf(NetLogic.Caps(vpn = true, internet = true)))   // una VPN sin red física conocida
    }

    @Test
    fun aVpnOnTopOfARealNetworkCountsTheRealNetwork() {
        assertEquals("wifi", NetLogic.typeOf(NetLogic.Caps(wifi = true, vpn = true)))
        assertEquals("cellular", NetLogic.typeOf(NetLogic.Caps(cellular = true, vpn = true)))
    }

    @Test
    fun whenSeveralTransportsAreListedTheFastestHomeOneWins() {
        assertEquals("wifi", NetLogic.typeOf(NetLogic.Caps(wifi = true, cellular = true)))
        assertEquals("ethernet", NetLogic.typeOf(NetLogic.Caps(ethernet = true, cellular = true)))
        assertEquals("cellular", NetLogic.typeOf(NetLogic.Caps(cellular = true, bluetooth = true)))
    }

    @Test
    fun meteredIsTheOppositeOfNotMetered() {
        assertTrue(NetLogic.metered(NetLogic.Caps(cellular = true)))
        assertFalse(NetLogic.metered(NetLogic.Caps(wifi = true, notMetered = true)))
        assertTrue("un WiFi que el usuario marcó «de pago» también lo es", NetLogic.metered(NetLogic.Caps(wifi = true, notMetered = false)))
    }

    @Test
    fun capsDefaultToNothing() {
        val c = NetLogic.Caps()
        assertFalse(c.wifi || c.cellular || c.ethernet || c.bluetooth || c.vpn || c.internet || c.validated || c.notMetered || c.captive)
    }
}
