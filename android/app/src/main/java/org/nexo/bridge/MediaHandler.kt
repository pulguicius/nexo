package org.nexo.bridge

import android.content.ComponentName
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Base64
import org.json.JSONObject
import java.io.ByteArrayOutputStream

/**
 * La música que suena en el móvil (Spotify, YouTube Music, VLC…): qué canción es, su estado, sus
 * botones y su carátula. Todo sale de las «sesiones de medios» de Android, que solo se pueden leer
 * con el acceso a notificaciones concedido (ver NexoNotificationListener).
 */
class MediaHandler(context: Context) {
    private val ctx: Context = context.applicationContext
    private val msm: MediaSessionManager? = ctx.getSystemService(Context.MEDIA_SESSION_SERVICE) as? MediaSessionManager
    private val component = ComponentName(ctx, NexoNotificationListener::class.java)
    private val main = Handler(Looper.getMainLooper())

    /** Lo asigna el servicio: se llama cuando cambia la canción, el estado o las sesiones. */
    @Volatile
    var onChange: (() -> Unit)? = null

    // ---------------------------------------------------------------- vigilar cambios

    private var watching = false
    private var watched: List<MediaController> = emptyList()

    private val sessionsListener = MediaSessionManager.OnActiveSessionsChangedListener { list ->
        synchronized(this) { rebind(list ?: emptyList()) }
        onChange?.invoke()
    }

    private val controllerCallback = object : MediaController.Callback() {
        override fun onPlaybackStateChanged(state: PlaybackState?) {
            onChange?.invoke()
        }

        override fun onMetadataChanged(metadata: MediaMetadata?) {
            onChange?.invoke()
        }

        override fun onSessionDestroyed() {
            onChange?.invoke()
        }
    }

    /** Empieza (o repite) la vigilancia si el acceso a notificaciones está concedido. */
    @Synchronized
    fun watch() {
        val m = msm ?: return
        if (!NexoNotificationListener.isEnabled(ctx)) {
            unwatch()
            return
        }
        try {
            if (!watching) {
                m.addOnActiveSessionsChangedListener(sessionsListener, component, main)
                watching = true
            }
            rebind(m.getActiveSessions(component))
        } catch (_: SecurityException) {
            watching = false
            rebind(emptyList())
        } catch (_: Exception) {
            // el sistema no está listo; el siguiente watch() lo reintenta
        }
    }

    @Synchronized
    fun unwatch() {
        val m = msm
        if (watching && m != null) {
            try {
                m.removeOnActiveSessionsChangedListener(sessionsListener)
            } catch (_: Exception) {
            }
        }
        watching = false
        rebind(emptyList())
    }

    /** Se queda escuchando a TODAS las sesiones activas: cualquiera puede ponerse a sonar. */
    private fun rebind(list: List<MediaController>) {
        for (c in watched) {
            try {
                c.unregisterCallback(controllerCallback)
            } catch (_: Exception) {
            }
        }
        for (c in list) {
            try {
                c.registerCallback(controllerCallback, main)
            } catch (_: Exception) {
            }
        }
        watched = list
    }

    // ---------------------------------------------------------------- sesiones

    private fun listenerOn(): Boolean = NexoNotificationListener.isEnabled(ctx)

    private fun sessions(): List<MediaController> {
        val m = msm ?: return emptyList()
        return try {
            m.getActiveSessions(component)
        } catch (_: SecurityException) {
            emptyList()
        }
    }

    /** La que está sonando; si no hay ninguna, la que estaba en pausa; si no, la más reciente. */
    private fun pick(list: List<MediaController>): MediaController? =
        list.maxByOrNull {
            when (stateName(it.playbackState)) {
                "playing" -> 3
                "buffering" -> 2
                "paused" -> 1
                else -> 0
            }
        }

    private fun requireSession(): MediaController {
        if (!listenerOn()) {
            UserAction.open(
                ctx, UserAction.ID_LISTENER, "Dar acceso a notificaciones",
                "Toca para concederle a Nexo el acceso: lo necesita para ver y controlar la música.",
                UserAction.notificationListenerSettings()
            )
            throw CmdException(
                "needs_user_action",
                "Falta el acceso a notificaciones: Android solo deja ver la música de otras apps con él. " +
                    "Te dejé una notificación que abre esos ajustes. " +
                    "(Android 13 o más: si el interruptor sale en gris, ve a Ajustes › Aplicaciones › Nexo › ⋮ › Permitir ajustes restringidos.)",
                JSONObject().put("action", "notification").put("opens", "notification_listener_settings")
            )
        }
        return pick(sessions()) ?: throw CmdException("not_found", "No hay ninguna app reproduciendo medios")
    }

    // ---------------------------------------------------------------- estado

    fun status(): JSONObject {
        val o = JSONObject()
        if (!listenerOn()) {
            return o.put("listener", false).put("available", false).put("state", "none")
        }
        val c = pick(sessions()) ?: return o.put("listener", true).put("available", false).put("state", "none")
        val md = c.metadata
        val ps = c.playbackState
        val pkg = c.packageName ?: ""
        val title = str(md, MediaMetadata.METADATA_KEY_TITLE) ?: str(md, MediaMetadata.METADATA_KEY_DISPLAY_TITLE)
        val artist = str(md, MediaMetadata.METADATA_KEY_ARTIST) ?: str(md, MediaMetadata.METADATA_KEY_DISPLAY_SUBTITLE)
        val album = str(md, MediaMetadata.METADATA_KEY_ALBUM)
        val albumArtist = str(md, MediaMetadata.METADATA_KEY_ALBUM_ARTIST)
        val duration = (md?.getLong(MediaMetadata.METADATA_KEY_DURATION) ?: 0L).let { if (it > 0) it else null }
        val actions = ps?.actions ?: 0L

        o.put("listener", true)
        o.put("available", true)
        o.put("package", pkg)
        o.putOrNull("app", appLabel(pkg))
        o.putOrNull("title", title)
        o.putOrNull("artist", artist)
        o.putOrNull("album", album)
        o.putOrNull("album_artist", albumArtist)
        o.put("state", stateName(ps))
        o.putOrNull("position_ms", positionOf(ps, duration ?: 0L))
        o.putOrNull("duration_ms", duration)
        val speed = ps?.playbackSpeed ?: 1f
        o.put("speed", if (speed == 0f) 1.0 else speed.toDouble())
        o.put("track_id", shortHash(pkg, str(md, MediaMetadata.METADATA_KEY_MEDIA_ID), title, artist, album, duration?.toString()))
        o.putOrNull("art_hash", artIdentity(pkg, md, title, album))
        o.put("can_play", has(actions, PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PLAY_PAUSE))
        o.put("can_pause", has(actions, PlaybackState.ACTION_PAUSE or PlaybackState.ACTION_PLAY_PAUSE))
        o.put("can_next", has(actions, PlaybackState.ACTION_SKIP_TO_NEXT))
        o.put("can_prev", has(actions, PlaybackState.ACTION_SKIP_TO_PREVIOUS))
        o.put("can_seek", has(actions, PlaybackState.ACTION_SEEK_TO))
        o.put("can_stop", has(actions, PlaybackState.ACTION_STOP))
        return o
    }

    private fun has(actions: Long, mask: Long): Boolean = (actions and mask) != 0L

    private fun str(md: MediaMetadata?, key: String): String? =
        try {
            md?.getString(key)?.takeIf { it.isNotBlank() }
        } catch (_: Exception) {
            null
        }

    private fun appLabel(pkg: String): String? = try {
        val pm = ctx.packageManager
        pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString()
    } catch (_: Exception) {
        null
    }

    // ---------------------------------------------------------------- controles

    fun control(cmd: String): JSONObject {
        val c = requireSession()
        val tc = c.transportControls
        val before = trackOf(c)
        val want: String? = when (cmd) {
            "media.play" -> {
                tc.play()
                "playing"
            }
            "media.pause" -> {
                tc.pause()
                "paused"
            }
            "media.stop" -> {
                tc.stop()
                "stopped"
            }
            "media.playpause" -> {
                val st = stateName(c.playbackState)
                if (st == "playing" || st == "buffering") {
                    tc.pause()
                    "paused"
                } else {
                    tc.play()
                    "playing"
                }
            }
            "media.next" -> {
                tc.skipToNext()
                null
            }
            "media.prev" -> {
                tc.skipToPrevious()
                null
            }
            else -> throw CmdException("unknown_command", "Comando desconocido: $cmd")
        }
        // El cambio llega unos milisegundos después: se espera un poco para poder contarlo en la respuesta.
        waitUntil(700) {
            if (want != null) stateName(c.playbackState) == want else trackOf(c) != before
        }
        return JSONObject().put("requested", true).put("state", stateName(c.playbackState))
    }

    fun seek(req: JSONObject): JSONObject {
        val c = requireSession()
        val duration = c.metadata?.getLong(MediaMetadata.METADATA_KEY_DURATION) ?: 0L
        val current = positionOf(c.playbackState, duration) ?: 0L
        val delta = req.opt("delta_ms")
        val absolute = req.opt("position_ms")
        val target: Long = when {
            delta is Number -> current + delta.toLong()
            absolute is Number -> absolute.toLong()
            else -> throw CmdException("bad_request", "Indica delta_ms o position_ms")
        }.coerceIn(0L, if (duration > 0) duration else Long.MAX_VALUE)
        c.transportControls.seekTo(target)
        return JSONObject().put("requested", true).put("position_ms", target)
    }

    private fun trackOf(c: MediaController): String {
        val md = c.metadata
        return shortHash(c.packageName, str(md, MediaMetadata.METADATA_KEY_MEDIA_ID), str(md, MediaMetadata.METADATA_KEY_TITLE))
    }

    // ---------------------------------------------------------------- carátula

    private data class Art(val hash: String, val data: String, val width: Int, val height: Int)

    @Volatile
    private var lastArt: Art? = null

    /** Identifica la carátula sin decodificarla: cambia cuando cambia la imagen (o la pista). */
    private fun artIdentity(pkg: String, md: MediaMetadata?, title: String?, album: String?): String? {
        if (md == null) return null
        for (k in ART_URI_KEYS) {
            val u = str(md, k)
            if (u != null) return shortHash("uri", pkg, u, title, album)
        }
        for (k in ART_BITMAP_KEYS) {
            val b = try {
                md.getBitmap(k)
            } catch (_: Exception) {
                null
            }
            if (b != null) return shortHash("bmp", pkg, "${b.width}x${b.height}", b.byteCount.toString(), title, album)
        }
        return null
    }

    fun art(): JSONObject {
        val c = requireSession()
        val md = c.metadata
        val pkg = c.packageName ?: ""
        val hash = artIdentity(pkg, md, str(md, MediaMetadata.METADATA_KEY_TITLE), str(md, MediaMetadata.METADATA_KEY_ALBUM))
            ?: throw CmdException("not_found", "La app no ofrece carátula")
        val cached = lastArt
        if (cached != null && cached.hash == hash) return artJson(cached)

        val src = loadArt(md) ?: throw CmdException("not_found", "La app no ofrece carátula")
        val made = encode(hash, src)
        lastArt = made
        return artJson(made)
    }

    private fun artJson(a: Art): JSONObject =
        JSONObject().put("hash", a.hash).put("mime", "image/jpeg").put("width", a.width).put("height", a.height).put("data", a.data)

    private fun loadArt(md: MediaMetadata?): Bitmap? {
        if (md == null) return null
        for (k in ART_BITMAP_KEYS) {
            val b = try {
                md.getBitmap(k)
            } catch (_: Exception) {
                null
            }
            if (b != null && !b.isRecycled) return b
        }
        for (k in ART_URI_KEYS) {
            val u = str(md, k) ?: continue
            val b = decodeContentUri(u)
            if (b != null) return b
        }
        return null
    }

    /** Solo `content://`: lo que la app que suena publicó para que otras la lean. Nunca se usa la red. */
    private fun decodeContentUri(uri: String): Bitmap? {
        val u = Uri.parse(uri)
        if (u.scheme != "content") return null
        return try {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            ctx.contentResolver.openInputStream(u)?.use { BitmapFactory.decodeStream(it, null, bounds) }
            var sample = 1
            val side = maxOf(bounds.outWidth, bounds.outHeight)
            while (side / sample > MAX_ART_SIDE * 2) sample *= 2
            val opts = BitmapFactory.Options().apply { inSampleSize = sample }
            ctx.contentResolver.openInputStream(u)?.use { BitmapFactory.decodeStream(it, null, opts) }
        } catch (_: Exception) {
            null
        }
    }

    /** Reduce a ≤320 px y comprime en JPEG hasta que quepa (~40 KB) en una sola línea del protocolo. */
    private fun encode(hash: String, original: Bitmap): Art {
        var src = original
        if (src.config == Bitmap.Config.HARDWARE) {
            src = src.copy(Bitmap.Config.ARGB_8888, false) ?: throw CmdException("failed", "No se pudo leer la carátula")
        }
        var side = MAX_ART_SIDE
        var best: Art? = null
        repeat(4) {
            val scale = minOf(1f, side.toFloat() / maxOf(src.width, src.height))
            val w = maxOf(1, (src.width * scale).toInt())
            val h = maxOf(1, (src.height * scale).toInt())
            val scaled = if (scale < 1f) Bitmap.createScaledBitmap(src, w, h, true) else src
            var q = 85
            while (q >= 40) {
                val bos = ByteArrayOutputStream()
                scaled.compress(Bitmap.CompressFormat.JPEG, q, bos)
                val art = Art(hash, Base64.encodeToString(bos.toByteArray(), Base64.NO_WRAP), scaled.width, scaled.height)
                best = art
                if (bos.size() <= MAX_ART_BYTES) return art
                q -= 15
            }
            side = side * 3 / 4
        }
        return best ?: throw CmdException("failed", "No se pudo preparar la carátula")
    }

    // ---------------------------------------------------------------- ayudas

    companion object {
        private const val MAX_ART_SIDE = 320
        private const val MAX_ART_BYTES = 40 * 1024

        private val ART_BITMAP_KEYS = arrayOf(
            MediaMetadata.METADATA_KEY_ALBUM_ART,
            MediaMetadata.METADATA_KEY_ART,
            MediaMetadata.METADATA_KEY_DISPLAY_ICON,
        )
        private val ART_URI_KEYS = arrayOf(
            MediaMetadata.METADATA_KEY_ALBUM_ART_URI,
            MediaMetadata.METADATA_KEY_ART_URI,
            MediaMetadata.METADATA_KEY_DISPLAY_ICON_URI,
        )

        fun stateName(s: PlaybackState?): String = when (s?.state) {
            PlaybackState.STATE_PLAYING, PlaybackState.STATE_FAST_FORWARDING, PlaybackState.STATE_REWINDING -> "playing"
            PlaybackState.STATE_PAUSED -> "paused"
            PlaybackState.STATE_STOPPED -> "stopped"
            PlaybackState.STATE_BUFFERING, PlaybackState.STATE_CONNECTING, PlaybackState.STATE_SKIPPING_TO_NEXT,
            PlaybackState.STATE_SKIPPING_TO_PREVIOUS, PlaybackState.STATE_SKIPPING_TO_QUEUE_ITEM -> "buffering"
            PlaybackState.STATE_ERROR -> "error"
            else -> "none"
        }

        /** Posición actual en ms, ya extrapolada al momento de la respuesta; null si la app no la dice. */
        fun positionOf(ps: PlaybackState?, durationMs: Long): Long? {
            if (ps == null || ps.position == PlaybackState.PLAYBACK_POSITION_UNKNOWN) return null
            var pos = ps.position
            if (stateName(ps) == "playing") {
                val dt = SystemClock.elapsedRealtime() - ps.lastPositionUpdateTime
                if (dt > 0) pos += (dt * ps.playbackSpeed).toLong()
            }
            if (durationMs > 0 && pos > durationMs) pos = durationMs
            return maxOf(0L, pos)
        }
    }
}
