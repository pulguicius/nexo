package org.nexo.bridge

import android.service.notification.NotificationListenerService
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pruebas en JVM (sin Android) de NotifLogic.kt: qué notificaciones se reenvían a Linux, cómo se recortan, cómo se evitan los avisos
 * repetidos y cuántas caben en una respuesta (protocolo 1.5). Lo que NO prueba: la conversación con Android
 * (NotifBridge.kt / NexoNotificationListener.kt), que solo se ha comprobado que compila (docs/LIMITACIONES.md).
 */
class NotifLogicTest {

    // ---------------------------------------------------------------------------------------------------- recortes

    @Test
    fun clipKeepsShortTextAndTrimsTheEdges() {
        assertEquals("", NotifLogic.clip(null, 10))
        assertEquals("", NotifLogic.clip("   ", 10))
        assertEquals("hola", NotifLogic.clip("  hola \n", 10))
        assertEquals("1234567890", NotifLogic.clip("1234567890", 10))
        assertEquals("", NotifLogic.clip("hola", 0))
    }

    @Test
    fun clipCutsToTheMaximumCountingTheEllipsis() {
        val out = NotifLogic.clip("abcdefghijklmnop", 10)
        assertEquals(10, out.length)
        assertEquals("abcdefghi…", out)
        assertEquals("…", NotifLogic.clip("abcdef", 1))
    }

    @Test
    fun clipNeverSplitsAnEmojiInHalf() {
        val smile = "😀"                            // 😀: dos unidades de texto
        val out = NotifLogic.clip("aaa" + smile + "bbb", 5)
        assertEquals("aaa…", out)
        assertTrue(out.none { Character.isSurrogate(it) })
        assertEquals("…", NotifLogic.clip(smile + smile + smile, 2))
        // si el emoji cabe entero, se queda
        assertEquals("aa" + smile + "…", NotifLogic.clip("aa" + smile + "bbbb", 5))
    }

    // ---------------------------------------------------------------------------------------------------- importancia

    @Test
    fun importanceStaysInTheAndroidRange() {
        for (i in 0..5) assertEquals(i, NotifLogic.importance(i))
        assertEquals(3, NotifLogic.importance(null))
        assertEquals(3, NotifLogic.importance(-1))
        assertEquals(3, NotifLogic.importance(6))
    }

    // ---------------------------------------------------------------------------------------------------- qué se reenvía

    @Test
    fun forwardsNormalNotifications() {
        assertTrue(NotifLogic.forward("com.whatsapp", "org.nexo.bridge", false, "msg"))
        assertTrue(NotifLogic.forward("com.whatsapp", "org.nexo.bridge", false, null))
        assertTrue(NotifLogic.forward("com.android.vending", "org.nexo.bridge", false, "progress"))
    }

    @Test
    fun doesNotForwardOwnGroupSummariesOrMediaControls() {
        assertFalse("las de Nexo serían un bucle", NotifLogic.forward("org.nexo.bridge", "org.nexo.bridge", false, null))
        assertFalse("un resumen de grupo repite a las demás", NotifLogic.forward("com.whatsapp", "org.nexo.bridge", true, "msg"))
        assertFalse("la música va por MPRIS", NotifLogic.forward("com.spotify.music", "org.nexo.bridge", false, "transport"))
    }

    @Test
    fun fingerprintChangesWithWhatTheUserSees() {
        val base = NotifLogic.fingerprint("t", "x", false, 3, "msg")
        assertEquals(base, NotifLogic.fingerprint("t", "x", false, 3, "msg"))
        assertNotEquals(base, NotifLogic.fingerprint("t2", "x", false, 3, "msg"))
        assertNotEquals(base, NotifLogic.fingerprint("t", "x2", false, 3, "msg"))
        assertNotEquals(base, NotifLogic.fingerprint("t", "x", true, 3, "msg"))
        assertNotEquals(base, NotifLogic.fingerprint("t", "x", false, 4, "msg"))
        assertNotEquals(base, NotifLogic.fingerprint("t", "x", false, 3, "call"))
        // el título y el texto no se pueden confundir moviendo el límite entre ellos
        assertNotEquals(NotifLogic.fingerprint("ab", "c", false, 3, null), NotifLogic.fingerprint("a", "bc", false, 3, null))
        assertEquals(NotifLogic.fingerprint("t", "x", false, 3, null), NotifLogic.fingerprint("t", "x", false, 3, ""))
    }

    // ---------------------------------------------------------------------------------------------------- motivos de baja

    @Test
    fun reasonNamesAreTheOnesInTheProtocol() {
        assertEquals("clicked", NotifLogic.reasonName(NotificationListenerService.REASON_CLICK))
        for (r in listOf(
            NotificationListenerService.REASON_CANCEL, NotificationListenerService.REASON_CANCEL_ALL,
            NotificationListenerService.REASON_LISTENER_CANCEL, NotificationListenerService.REASON_LISTENER_CANCEL_ALL
        )) assertEquals("dismissed", NotifLogic.reasonName(r))
        assertEquals("cancelled", NotifLogic.reasonName(NotificationListenerService.REASON_APP_CANCEL))
        assertEquals("cancelled", NotifLogic.reasonName(NotificationListenerService.REASON_APP_CANCEL_ALL))
        assertEquals("timeout", NotifLogic.reasonName(NotificationListenerService.REASON_TIMEOUT))
    }

    @Test
    fun anyOtherReasonIsOther() {
        for (r in listOf(
            NotificationListenerService.REASON_PACKAGE_CHANGED, NotificationListenerService.REASON_ERROR,
            NotificationListenerService.REASON_SNOOZED, NotificationListenerService.REASON_CHANNEL_BANNED, 0, -1, 9999
        )) assertEquals("other", NotifLogic.reasonName(r))
    }

    // ---------------------------------------------------------------------------------------------------- cuántas caben

    @Test
    fun takeWithinRespectsCountAndBytes() {
        assertEquals(0, NotifLogic.takeWithin(emptyList(), 40, 1000))
        assertEquals(3, NotifLogic.takeWithin(listOf(10, 10, 10), 40, 1000))
        assertEquals(2, NotifLogic.takeWithin(listOf(10, 10, 10), 2, 1000))
        assertEquals(0, NotifLogic.takeWithin(listOf(10, 10, 10), 0, 1000))
    }

    @Test
    fun takeWithinCountsTheCommasBetweenElements() {
        // 10 + 1 + 10 = 21 bytes caben justo en 21, pero no en 20
        assertEquals(2, NotifLogic.takeWithin(listOf(10, 10, 10), 40, 21))
        assertEquals(1, NotifLogic.takeWithin(listOf(10, 10, 10), 40, 20))
        assertEquals(0, NotifLogic.takeWithin(listOf(100, 1), 40, 99))
    }

    @Test
    fun theListBudgetFitsInOneProtocolLine() {
        assertTrue("una línea del protocolo mide como mucho 64 KiB", NotifLogic.MAX_LIST_BYTES + 2048 < 64 * 1024)
        assertTrue(NotifLogic.MAX_LIST in 1..100)
    }

    // ---------------------------------------------------------------------------------------------------- repeticiones

    @Test
    fun dedupeAllowsTheFirstPostAndChanges() {
        val d = NotifLogic.Dedupe(10_000L, 100)
        assertTrue(d.allow("k", "a", false, 0L))
        assertTrue("el contenido cambió", d.allow("k", "b", false, 1L))
        assertTrue("otra notificación", d.allow("k2", "b", false, 2L))
    }

    @Test
    fun dedupeDropsIdenticalRepostsUntilTheRepeatTime() {
        val d = NotifLogic.Dedupe(10_000L, 100)
        assertTrue(d.allow("k", "a", false, 0L))
        assertFalse(d.allow("k", "a", false, 500L))
        assertFalse(d.allow("k", "a", false, 9_999L))
        assertTrue("pasó el rato: puede ser otro «Llamada perdida» igual", d.allow("k", "a", false, 10_000L))
        assertFalse("y vuelve a empezar a contar", d.allow("k", "a", false, 10_500L))
    }

    @Test
    fun dedupeNeverRepeatsAnOngoingNotificationThatDidNotChange() {
        val d = NotifLogic.Dedupe(10_000L, 100)
        assertTrue(d.allow("k", "a", true, 0L))
        assertFalse(d.allow("k", "a", true, 60_000L))
        assertTrue(d.allow("k", "b", true, 60_001L))
    }

    @Test
    fun dedupeForgetSaysWhetherItWasForwarded() {
        val d = NotifLogic.Dedupe(10_000L, 100)
        assertFalse("nunca se reenvió", d.forget("k"))
        assertTrue(d.allow("k", "a", false, 0L))
        assertTrue(d.forget("k"))
        assertFalse("ya se olvidó", d.forget("k"))
        assertTrue("tras quitarla, la misma vuelve a avisarse", d.allow("k", "a", false, 1L))
        d.clear()
        assertFalse(d.forget("k"))
    }

    @Test
    fun dedupeKeepsAtMostMaxEntriesForgettingTheOldest() {
        val d = NotifLogic.Dedupe(10_000L, 3)
        for (k in listOf("k1", "k2", "k3", "k4")) assertTrue(d.allow(k, "a", false, 0L))
        assertFalse("la más antigua se olvidó para no crecer sin fin", d.forget("k1"))
        assertTrue(d.forget("k4"))
        assertTrue(d.forget("k2"))
    }

    // ---------------------------------------------------------------------------------------------------- límite de ráfagas

    @Test
    fun limiterAllowsAtMostMaxPerWindow() {
        val l = NotifLogic.Limiter(3, 1_000L)
        assertTrue(l.allow(0L))
        assertTrue(l.allow(1L))
        assertTrue(l.allow(2L))
        assertFalse(l.allow(3L))
        assertFalse(l.allow(999L))
        assertTrue("la primera ya salió de la ventana", l.allow(1_000L))
        assertTrue("la segunda, un milisegundo después", l.allow(1_001L))
        assertTrue("y la tercera", l.allow(1_002L))
        assertFalse("ahora las tres de la ventana son nuevas", l.allow(1_003L))
    }

    @Test
    fun limiterDoesNotCountTheOnesItRejected() {
        val l = NotifLogic.Limiter(1, 100L)
        assertTrue(l.allow(0L))
        for (t in 1L..99L) assertFalse(l.allow(t))
        assertTrue("100 ms después de la que sí pasó, no de las rechazadas", l.allow(100L))
    }
}
