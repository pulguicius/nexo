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

/** Longitud de prefijo (24) de una máscara en el formato de DhcpInfo; null si no es una máscara válida. */
fun prefixFromNetmask(mask: Int): Int? {
    if (mask == 0) return null
    val be = Integer.reverseBytes(mask) // de "little endian" a la forma normal 255.255.255.0 = 0xFFFFFF00
    val n = Integer.bitCount(be)
    return if (n in 1..32 && be == (-1 shl (32 - n))) n else null
}

/** 24 → "255.255.255.0" */
fun netmaskText(prefix: Int): String {
    val m = if (prefix <= 0) 0 else (-1 shl (32 - prefix.coerceAtMost(32)))
    return "${(m ushr 24) and 0xff}.${(m ushr 16) and 0xff}.${(m ushr 8) and 0xff}.${m and 0xff}"
}

/** Hash corto y estable (SHA-1 en hexadecimal, 16 caracteres) para identificar pistas y carátulas. */
fun shortHash(vararg parts: String?): String {
    val md = java.security.MessageDigest.getInstance("SHA-1")
    for (p in parts) {
        md.update((p ?: "").toByteArray(Charsets.UTF_8))
        md.update(0)
    }
    return md.digest().joinToString("") { String.format("%02x", it) }.take(16)
}
