package com.novel.novel

import android.app.ActivityManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.BatteryManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import java.io.File
import java.io.RandomAccessFile

/**
 * 锁屏/后台运行, 听书 and model downloads behind the screen: Android lets an
 * app off screen go on only as a foreground service, with a notification, and
 * the CPU sleeps under a locked screen unless held awake. One service for
 * every reason (keep_alive.dart), up while any holds. Like iOS's silent
 * player it can only start while the app is on screen.
 */
class KeepService : Service() {
    companion object {
        private val reasons = linkedSetOf<String>()
        private var running: KeepService? = null

        fun clear(context: Context) {
            reasons.clear()
            context.stopService(Intent(context, KeepService::class.java))
        }

        /** False when Android would not let it start (the app is behind). */
        fun set(context: Context, reason: String, on: Boolean): Boolean {
            val changed = if (on) reasons.add(reason) else reasons.remove(reason)
            if (!changed) return true
            val intent = Intent(context, KeepService::class.java)
            if (reasons.isEmpty()) {
                context.stopService(intent)
                return true
            }
            // Already up: only what it says it is for changes, which needs no
            // start, and so no app on screen.
            running?.let { return it.show() }
            return try {
                // Delivered to onStartCommand, which shows what it is for now.
                if (Build.VERSION.SDK_INT >= 26) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
                true
            } catch (e: Exception) {
                reasons.remove(reason)
                if (reasons.isEmpty()) context.stopService(intent)
                false
            }
        }
    }

    private var awake: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        running = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (reasons.isEmpty()) stopSelf() else show()
        return START_NOT_STICKY
    }

    /** In the foreground for what it is held for now, and the CPU awake. */
    fun show(): Boolean {
        val listening = "listen" in reasons
        try {
            if (Build.VERSION.SDK_INT >= 34) {
                var types = 0
                if (listening) types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
                if (reasons.any { it != "listen" }) {
                    types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
                }
                startForeground(1, notification(listening), types)
            } else {
                startForeground(1, notification(listening))
            }
        } catch (e: Exception) {
            reasons.clear()
            stopSelf()
            return false
        }
        if (awake == null) {
            val power = getSystemService(Context.POWER_SERVICE) as PowerManager
            awake = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "novel:keep").apply {
                setReferenceCounted(false)
                acquire()
            }
        }
        return true
    }

    override fun onDestroy() {
        awake?.let { if (it.isHeld) it.release() }
        awake = null
        running = null
        super.onDestroy()
    }

    private fun notification(listening: Boolean): Notification {
        val channel = "keep"
        if (Build.VERSION.SDK_INT >= 26) {
            val manager = getSystemService(NotificationManager::class.java)
            if (manager.getNotificationChannel(channel) == null) {
                manager.createNotificationChannel(
                    NotificationChannel(channel, "后台运行", NotificationManager.IMPORTANCE_LOW)
                )
            }
        }
        val open = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val text = when {
            listening -> "正在听书"
            reasons.size == 1 && "download" in reasons -> "正在下载"
            else -> "正在后台处理"
        }
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(this, channel)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(
                if (listening) android.R.drawable.ic_media_play
                else android.R.drawable.stat_notify_sync
            )
            .setContentTitle("挚阅")
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(true)
            .build()
    }
}

/** What the AI queue waits on, and the 设备 card shows (platform_services.dart). */
object DeviceInfo {
    /** How warm the phone judges itself, its memory, its power. */
    fun read(context: Context): Map<String, Any> {
        val state = mutableMapOf<String, Any>("thermal" to thermal(context))
        val activity = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val memory = ActivityManager.MemoryInfo()
        activity.getMemoryInfo(memory)
        state["memoryMb"] = (memory.totalMem shr 20).toInt()
        val battery = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        if (battery != null) {
            val level = battery.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
            val scale = battery.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
            if (level >= 0 && scale > 0) {
                state["battery"] = (level * 100f / scale).toInt()
                val status = battery.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
                state["charging"] = status == BatteryManager.BATTERY_STATUS_CHARGING ||
                    status == BatteryManager.BATTERY_STATUS_FULL
            }
        }
        return state
    }

    /** The battery's temperature, in tenths of a degree. Android shows an app
     * no CPU or GPU load. */
    fun load(context: Context): Map<String, Any> {
        val battery = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val tenths = battery?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, Int.MIN_VALUE)
        return if (tenths == null || tenths == Int.MIN_VALUE) emptyMap()
        else mapOf("batteryTenths" to tenths)
    }

    private fun thermal(context: Context): String {
        if (Build.VERSION.SDK_INT < 29) return "unavailable"
        val power = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        return when (power.currentThermalStatus) {
            PowerManager.THERMAL_STATUS_NONE, PowerManager.THERMAL_STATUS_LIGHT -> "nominal"
            PowerManager.THERMAL_STATUS_MODERATE -> "fair"
            PowerManager.THERMAL_STATUS_SEVERE -> "serious"
            else -> "critical"
        }
    }
}

/**
 * A spoken chapter's WAV as AAC in an .m4a (tts_chapters.dart), as
 * AppDelegate.swift writes it on iPhone: 64 kbit/s, a sixth of the WAV, and
 * lower rates tried after it should the encoder not take that one.
 */
object AudioEncoder {
    /** Null when written, why not otherwise. */
    fun m4a(from: String, to: String): String? {
        var why = "无法编码"
        for (rate in intArrayOf(64000, 48000, 32000)) {
            try {
                encode(from, to, rate)
                return null
            } catch (e: Exception) {
                why = e.message ?: why
                File(to).delete()
            }
        }
        return why
    }

    private fun le16(b: ByteArray, at: Int) =
        (b[at].toInt() and 0xff) or ((b[at + 1].toInt() and 0xff) shl 8)

    private fun le32(b: ByteArray, at: Int) = le16(b, at) or (le16(b, at + 2) shl 16)

    private fun encode(from: String, to: String, bitRate: Int) {
        RandomAccessFile(from, "r").use { wav ->
            val head = ByteArray(12)
            wav.readFully(head)
            require(String(head, 0, 4, Charsets.US_ASCII) == "RIFF" &&
                String(head, 8, 4, Charsets.US_ASCII) == "WAVE") { "不是 WAV" }
            var format = 0
            var channels = 0
            var sampleRate = 0
            var bits = 0
            var dataStart = -1L
            var dataLength = 0L
            val chunk = ByteArray(8)
            while (wav.filePointer + 8 <= wav.length()) {
                wav.readFully(chunk)
                val id = String(chunk, 0, 4, Charsets.US_ASCII)
                val size = le32(chunk, 4).toLong() and 0xffffffffL
                if (id == "data") {
                    dataStart = wav.filePointer
                    dataLength = minOf(size, wav.length() - dataStart)
                    break
                }
                if (id == "fmt " && size >= 16) {
                    val fmt = ByteArray(16)
                    wav.readFully(fmt)
                    format = le16(fmt, 0)
                    channels = le16(fmt, 2)
                    sampleRate = le32(fmt, 4)
                    bits = le16(fmt, 14)
                    wav.seek(wav.filePointer + size - 16 + (size and 1))
                } else {
                    wav.seek(wav.filePointer + size + (size and 1))
                }
            }
            require(format == 1 && bits == 16 && channels in 1..2 && sampleRate > 0 && dataStart >= 0) {
                "WAV 格式不支持"
            }
            wav.seek(dataStart)

            val mime = MediaFormat.MIMETYPE_AUDIO_AAC
            val wanted = MediaFormat.createAudioFormat(mime, sampleRate, channels).apply {
                setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                setInteger(MediaFormat.KEY_BIT_RATE, bitRate)
                setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 1 shl 16)
            }
            val codec = MediaCodec.createEncoderByType(mime)
            val muxer = MediaMuxer(to, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            var track = -1
            var started = false
            try {
                codec.configure(wanted, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                codec.start()
                val frame = 2 * channels
                val bytes = ByteArray(1 shl 14)
                val info = MediaCodec.BufferInfo()
                var read = 0L
                var fed = false
                while (true) {
                    if (!fed) {
                        val i = codec.dequeueInputBuffer(10_000)
                        if (i >= 0) {
                            val input = codec.getInputBuffer(i)!!
                            input.clear()
                            val n = (minOf(input.capacity().toLong(), dataLength - read, bytes.size.toLong())
                                .toInt() / frame) * frame
                            val time = read / frame * 1_000_000L / sampleRate
                            if (n <= 0) {
                                codec.queueInputBuffer(i, 0, 0, time, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                fed = true
                            } else {
                                wav.readFully(bytes, 0, n)
                                input.put(bytes, 0, n)
                                codec.queueInputBuffer(i, 0, n, time, 0)
                                read += n
                            }
                        }
                    }
                    val o = codec.dequeueOutputBuffer(info, 10_000)
                    if (o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                        track = muxer.addTrack(codec.outputFormat)
                        muxer.start()
                        started = true
                    } else if (o >= 0) {
                        val output = codec.getOutputBuffer(o)!!
                        if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) info.size = 0
                        if (info.size > 0 && started) {
                            output.position(info.offset)
                            output.limit(info.offset + info.size)
                            muxer.writeSampleData(track, output, info)
                        }
                        codec.releaseOutputBuffer(o, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                    }
                }
                require(started) { "编码器没有输出" }
            } finally {
                runCatching { codec.stop() }
                codec.release()
                if (started) runCatching { muxer.stop() }
                muxer.release()
            }
        }
    }
}
