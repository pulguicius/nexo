package org.nexo.bridge

/** Espera (mirando cada 100 ms) a que se cumpla la condición o se acabe el tiempo. */
inline fun waitUntil(timeoutMs: Long, cond: () -> Boolean): Boolean {
    val end = System.currentTimeMillis() + timeoutMs
    while (System.currentTimeMillis() < end) {
        if (cond()) return true
        Thread.sleep(100)
    }
    return cond()
}

/** WifiInfo.getIpAddress() devuelve la IPv4 como entero "al revés" (little endian). */
fun ipToString(ip: Int): String? =
    if (ip == 0) null
    else "${ip and 0xff}.${(ip shr 8) and 0xff}.${(ip shr 16) and 0xff}.${(ip shr 24) and 0xff}"
