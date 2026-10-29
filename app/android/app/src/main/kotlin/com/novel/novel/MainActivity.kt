package com.novel.novel

import android.media.AudioAttributes
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

class MainActivity : FlutterActivity() {
    private var speech: SystemSpeech? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        val channel = MethodChannel(messenger, "novel/speech")
        val s = SystemSpeech(this, channel)
        channel.setMethodCallHandler { call, result -> s.handle(call, result) }
        speech = s

        val app = applicationContext
        MethodChannel(messenger, "novel/keep").setMethodCallHandler { call, result ->
            val reason = call.argument<String>("reason")
            if (call.method != "set" || reason == null) {
                result.notImplemented()
            } else {
                result.success(KeepService.set(app, reason, call.argument<Boolean>("on") == true))
            }
        }
        MethodChannel(messenger, "novel/device").setMethodCallHandler { call, result ->
            result.success(
                if (call.method == "load") DeviceInfo.load(app) else DeviceInfo.read(app)
            )
        }
        val main = Handler(Looper.getMainLooper())
        MethodChannel(messenger, "novel/audio").setMethodCallHandler { call, result ->
            val from = call.argument<String>("from")
            val to = call.argument<String>("to")
            if (call.method != "m4a" || from == null || to == null) {
                result.notImplemented()
                return@setMethodCallHandler
            }
            // Off the main thread: a chapter takes a few seconds to encode.
            Thread {
                val failure = AudioEncoder.m4a(from, to)
                main.post {
                    if (failure == null) result.success(null) else result.error("m4a", failure, null)
                }
            }.start()
        }
    }

    override fun onDestroy() {
        speech?.shutdown()
        speech = null
        // The app's Dart side goes with this activity: nothing is left to
        // keep running for.
        if (!isChangingConfigurations) KeepService.clear(applicationContext)
        super.onDestroy()
    }
}

/**
 * 听书 without the AI voice: the phone's own (tts_controller.dart), as
 * AppDelegate.swift's SystemSpeech does on iPhone. A chapter from a sentence
 * on is queued all at once; Dart hears which sentence has begun, and when the
 * last has been said. The system voice cannot pause, so pause stops and
 * resume answers false: Dart reads on from the sentence it was at.
 */
class SystemSpeech(activity: FlutterActivity, private val channel: MethodChannel) {
    private val main = Handler(Looper.getMainLooper())
    private var tts: TextToSpeech? = null
    private var ready = false
    private var failed = false

    /** Calls made before the voice has started, run once it has. */
    private val waiting = mutableListOf<() -> Unit>()

    /** Which queue the callbacks belong to; an older one's are ignored. */
    private var gen = 0
    private var from = 0
    private var lastId: String? = null

    init {
        tts = TextToSpeech(activity.applicationContext) { status ->
            main.post {
                ready = status == TextToSpeech.SUCCESS
                failed = !ready
                val calls = waiting.toList()
                waiting.clear()
                calls.forEach { it() }
            }
        }
        tts?.setAudioAttributes(
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build()
        )
        tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String) {
                main.post { started(utteranceId) }
            }

            override fun onDone(utteranceId: String) {
                main.post { done(utteranceId) }
            }

            @Deprecated("Deprecated in Java")
            override fun onError(utteranceId: String) {
                main.post { done(utteranceId) }
            }
        })
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "speak", "pause", "stop" -> {}
            "resume" -> {
                result.success(false)
                return
            }
            else -> {
                result.notImplemented()
                return
            }
        }
        val go = { perform(call, result) }
        if (ready || failed) go() else waiting.add(go)
    }

    private fun perform(call: MethodCall, result: MethodChannel.Result) {
        val t = tts
        if (t == null || !ready) {
            if (call.method == "speak") {
                result.error("no_voice", "手机没有可用的朗读语音", null)
            } else {
                result.success(true)
            }
            return
        }
        when (call.method) {
            "speak" -> {
                clear()
                val lang = t.setLanguage(Locale.SIMPLIFIED_CHINESE)
                if (lang == TextToSpeech.LANG_MISSING_DATA ||
                    lang == TextToSpeech.LANG_NOT_SUPPORTED
                ) {
                    result.error("no_voice", "手机没有中文朗读语音", null)
                    return
                }
                val texts = call.argument<List<String>>("texts") ?: emptyList()
                val gaps = call.argument<List<Double>>("gaps") ?: emptyList()
                // Dart's pace is the iPhone voice's: 0.5 is its own pace.
                val rate = call.argument<Double>("rate") ?: 0.5
                t.setSpeechRate((rate * 2).toFloat().coerceIn(0.25f, 3f))
                from = call.argument<Int>("from") ?: 0
                for ((k, text) in texts.withIndex()) {
                    val id = "$gen:s:$k"
                    t.speak(text, TextToSpeech.QUEUE_ADD, null, id)
                    lastId = id
                    val gap = ((gaps.getOrNull(k) ?: 0.0) * 1000).toLong()
                    if (gap > 0) {
                        val g = "$gen:g:$k"
                        t.playSilentUtterance(gap, TextToSpeech.QUEUE_ADD, g)
                        lastId = g
                    }
                }
            }
            "pause", "stop" -> clear()
        }
        result.success(true)
    }

    /** What was queued is let go first, so nothing it says on its way out is
     * taken for what follows. */
    private fun clear() {
        gen++
        lastId = null
        tts?.stop()
    }

    private fun started(id: String) {
        val parts = id.split(':')
        if (parts.size != 3 || parts[0] != gen.toString() || parts[1] != "s") return
        channel.invokeMethod("sentence", from + parts[2].toInt())
    }

    private fun done(id: String) {
        if (id != lastId) return
        lastId = null
        channel.invokeMethod("end", null)
    }

    fun shutdown() {
        clear()
        tts?.shutdown()
        tts = null
        ready = false
    }
}
