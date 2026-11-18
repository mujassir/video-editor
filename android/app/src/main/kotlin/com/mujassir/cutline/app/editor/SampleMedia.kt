package com.mujassir.cutline.app.editor

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Shader
import com.mujassir.cutline.core.duration
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.DataOutputStream
import java.io.File
import java.io.FileOutputStream
import kotlin.math.PI
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.sin

/**
 * Bundled sample media for UI tests and demos only (launched with `-sampleMedia`, IMPLEMENTATION §14).
 * Never offered to users. Photos are generated gradients; the four music tracks are synthesised.
 */
object SampleMedia {
    data class Track(val id: String, val title: String, val root: Double, val minor: Boolean, val bpm: Int)

    val tracks = listOf(
        Track("sunrise", "Sunrise Drive", 261.63, false, 112),
        Track("night", "Night Walk", 220.0, true, 90),
        Track("chill", "Chill Loop", 196.0, false, 80),
        Track("epic", "Epic Rise", 146.83, true, 128),
    )

    private val colors = listOf(0xFFFF3C61.toInt() to 0xFF8A33F2.toInt(), 0xFF2E8BFF.toInt() to 0xFF33BF8C.toInt(), 0xFFF29933.toInt() to 0xFFE04040.toInt())

    fun importInto(model: EditorModel) {
        model.scope.launch {
            val files = withContext(Dispatchers.IO) {
                colors.mapIndexed { i, (a, b) ->
                    File(model.store.root, "sample-$i.png").also { f ->
                        if (!f.exists()) {
                            val bmp = Bitmap.createBitmap(1280, 720, Bitmap.Config.ARGB_8888)
                            Canvas(bmp).drawRect(0f, 0f, 1280f, 720f, Paint().apply { shader = LinearGradient(0f, 0f, 1280f, 720f, a, b, Shader.TileMode.CLAMP) })
                            FileOutputStream(f).use { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }
                        }
                    }
                }
            }
            model.importFiles(files)
        }
    }

    /** Synthetic video clip(s) with sound for Reverse / Denoise / Cutout / Captions / SPD UI tests. */
    fun importVideoInto(model: EditorModel, count: Int = 1) {
        model.addDemoVideoClip(durationSeconds = 4.0, withAudio = true, count = count)
    }

    fun addTrack(model: EditorModel, t: Track) {
        model.scope.launch {
            val seconds = max(model.project.duration.seconds, 10.0)
            val file = File(model.store.root, "music-${t.id}-${seconds.toInt()}.wav")
            withContext(Dispatchers.IO) { if (!file.exists()) writeTrack(file, t, seconds) }
            model.addMusic(file, t.title)
        }
    }

    /** A simple arpeggio in the track's key, 22.05 kHz mono 16-bit WAV. */
    private fun writeTrack(file: File, t: Track, seconds: Double) {
        val rate = 22_050
        val n = (seconds * rate).toInt()
        val steps = if (t.minor) intArrayOf(0, 3, 7, 10, 12, 10, 7, 3) else intArrayOf(0, 4, 7, 11, 12, 11, 7, 4)
        val beat = 60.0 / t.bpm / 2
        DataOutputStream(FileOutputStream(file).buffered()).use { out ->
            fun le32(v: Int) = out.write(byteArrayOf(v.toByte(), (v shr 8).toByte(), (v shr 16).toByte(), (v shr 24).toByte()))
            fun le16(v: Int) = out.write(byteArrayOf(v.toByte(), (v shr 8).toByte()))
            out.writeBytes("RIFF"); le32(36 + n * 2); out.writeBytes("WAVEfmt "); le32(16); le16(1); le16(1); le32(rate); le32(rate * 2); le16(2); le16(16)
            out.writeBytes("data"); le32(n * 2)
            for (i in 0 until n) {
                val time = i.toDouble() / rate
                val k = (time / beat).toInt()
                val f = t.root * Math.pow(2.0, steps[k % steps.size] / 12.0)
                val local = time - k * beat
                val env = exp(-local * 5)
                val v = (sin(2 * PI * f * time) * 0.35 + sin(2 * PI * t.root / 2 * time) * 0.15) * env
                le16((v * 32767).toInt().coerceIn(-32768, 32767))
            }
        }
    }
}
