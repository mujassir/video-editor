package com.mujassir.cutline.engine

import android.content.Context
import android.os.Build
import android.speech.SpeechRecognizer
import com.mujassir.cutline.core.CaptionSegment
import com.mujassir.cutline.core.CaptionWord
import com.mujassir.cutline.core.MediaKind
import com.mujassir.cutline.core.MediaTime
import com.mujassir.cutline.core.MediaTimeRange
import com.mujassir.cutline.core.Project
import com.mujassir.cutline.core.ProjectStore
import com.mujassir.cutline.core.duration
import com.mujassir.cutline.core.groupCaptions
import java.io.File
import kotlin.math.sqrt

/**
 * CAP-1 captions pipeline (IMPLEMENTATION §10.1).
 *
 * Sample/demo media uses [demoWords]. Real projects mix speech audio then attempt on-device STT.
 * Android's [SpeechRecognizer] is mic-oriented; until a file-capable on-device engine (whisper.cpp)
 * is bundled, [transcribeFile] returns null when the platform can't take a file, and the UI shows
 * the FEATURES unavailable message.
 */
object CaptionGenerator {
    sealed class Result {
        data class Ok(val segments: List<CaptionSegment>, val wordCount: Int) : Result()
        data object NoSpeech : Result()
        data object Unavailable : Result()
    }

    /** Timed demo words for Robolectric / `-sampleMedia` (UI tests). */
    fun demoWords(duration: MediaTime): List<CaptionWord> {
        val script = listOf("Welcome", "to", "Cutline", "edit", "on", "your", "phone")
        val end = MediaTime.max(duration, MediaTime.seconds(3.5))
        val step = end.ticks / script.size
        return script.mapIndexed { i, w ->
            val start = MediaTime(step * i)
            val stop = if (i == script.lastIndex) end else MediaTime(step * (i + 1))
            CaptionWord(w, MediaTimeRange.of(start, stop))
        }
    }

    fun segments(words: List<CaptionWord>): List<CaptionSegment> = groupCaptions(words)

    fun isOnDeviceAvailable(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < 33) return false
        return runCatching { SpeechRecognizer.isOnDeviceRecognitionAvailable(context) }.getOrDefault(false)
    }

    /**
     * Builds captions for [project]. When [demo] is true, installs demo words (sample media / tests).
     * Otherwise mixes speech audio and attempts on-device file transcription.
     */
    fun generate(
        context: Context,
        project: Project,
        store: ProjectStore,
        demo: Boolean,
        onProgress: (Double) -> Unit = {},
    ): Result {
        if (demo) {
            onProgress(1.0)
            val words = demoWords(project.duration)
            return if (words.isEmpty()) Result.NoSpeech
            else Result.Ok(segments(words), words.size)
        }
        if (!project.clips.any { it.kind == MediaKind.VIDEO }) return Result.NoSpeech
        onProgress(0.1)
        val mix = SpeechMix.write(project, store) ?: return Result.NoSpeech
        onProgress(0.5)
        if (!SpeechMix.hasSpeechEnergy(mix)) return Result.NoSpeech
        if (!isOnDeviceAvailable(context)) return Result.Unavailable
        onProgress(0.7)
        val words = transcribeFile(context, mix) ?: return Result.Unavailable
        onProgress(1.0)
        if (words.isEmpty()) return Result.NoSpeech
        return Result.Ok(segments(words), words.size)
    }

    /**
     * File transcription hook. Returns null when the platform can't take a file (typical today),
     * empty list when recognition runs but hears nothing.
     */
    fun transcribeFile(context: Context, audioFile: File): List<CaptionWord>? {
        // Platform SpeechRecognizer has no supported file input API (mic-oriented). Keep this
        // null so callers surface FEATURES' unavailable message until whisper.cpp (or similar)
        // is bundled. [context] / [audioFile] are accepted for the future plug-in point.
        if (!audioFile.exists() || !isOnDeviceAvailable(context)) return null
        return null
    }
}

/**
 * Mixes main-track clip sound (no music / effects) to 16 kHz mono WAV for CAP-1 (§10.1).
 */
object SpeechMix {
    private const val RATE = 16_000

    fun write(project: Project, store: ProjectStore): File? {
        val dir = store.cacheDirectory(project.id)
        dir.mkdirs()
        val out = File(dir, "speech-mix.wav")
        val pieces = ArrayList<FloatArray>()
        var total = 0
        for (clip in project.clips) {
            if (clip.kind != MediaKind.VIDEO || clip.isMuted || clip.isReversed || clip.volume <= 0) continue
            val media = project.mediaItem(clip.mediaID) ?: continue
            if (!media.hasAudio) continue
            val file = store.mediaFile(media, project.id)
            val decoded = AudioDecoder.decodeToFloat(file, RATE, maxChannels = 1) ?: continue
            val mono = decoded.channels.firstOrNull() ?: continue
            // Keep the clip's source range (approx by sample index at 16 kHz).
            val start = (clip.sourceRange.start.seconds * RATE).toInt().coerceIn(0, mono.size)
            val end = (clip.sourceRange.end.seconds * RATE).toInt().coerceIn(start, mono.size)
            if (end <= start) continue
            val slice = mono.copyOfRange(start, end)
            // Speed: stretch/shrink by resampling when speed ≠ 1.
            val timed = if (clip.speed == 1.0) slice else resampleLength(slice, (slice.size / clip.speed).toInt().coerceAtLeast(1))
            val gain = clip.volume.toFloat()
            if (gain != 1f) for (i in timed.indices) timed[i] *= gain
            pieces += timed
            total += timed.size
        }
        if (total == 0) return null
        val mix = FloatArray(total)
        var o = 0
        for (p in pieces) {
            System.arraycopy(p, 0, mix, o, p.size)
            o += p.size
        }
        if (!hasEnergy(mix)) return null
        WavWriter.write(out, listOf(mix), RATE, leadingSilence = 0)
        return out.takeIf { it.exists() && it.length() > 44 }
    }

    fun hasSpeechEnergy(file: File): Boolean = file.exists() && file.length() > 44

    fun hasEnergy(samples: FloatArray, threshold: Float = 0.01f): Boolean {
        if (samples.isEmpty()) return false
        var sum = 0.0
        for (s in samples) sum += s * s
        return sqrt(sum / samples.size) > threshold
    }

    private fun resampleLength(input: FloatArray, outLen: Int): FloatArray {
        if (input.isEmpty() || outLen <= 0) return FloatArray(0)
        if (outLen == input.size) return input.copyOf()
        val out = FloatArray(outLen)
        val ratio = (input.size - 1).toDouble() / (outLen - 1).coerceAtLeast(1)
        for (i in 0 until outLen) {
            val src = i * ratio
            val i0 = src.toInt().coerceIn(0, input.lastIndex)
            val i1 = (i0 + 1).coerceAtMost(input.lastIndex)
            val t = (src - i0).toFloat()
            out[i] = input[i0] * (1 - t) + input[i1] * t
        }
        return out
    }
}
