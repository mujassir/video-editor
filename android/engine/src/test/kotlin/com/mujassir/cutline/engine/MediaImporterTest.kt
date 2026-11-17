package com.mujassir.cutline.engine

import com.mujassir.cutline.core.MediaKind
import com.mujassir.cutline.core.MediaTime
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.DataOutputStream
import java.io.File
import java.io.FileOutputStream
import kotlin.math.PI
import kotlin.math.sin

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class MediaImporterTest {
    @Test fun `IMP sample WAV probe reads duration without MediaMetadataRetriever`() {
        val file = File.createTempFile("sunrise", ".wav")
        writeTone(file, seconds = 2.5)
        val item = MediaImporter.probeWav(file, file.name, "Sunrise Drive")
        assertNotNull(item)
        assertEquals(MediaKind.AUDIO, item!!.kind)
        assertTrue(item.hasAudio)
        assertEquals(MediaTime.seconds(2.5).ticks, item.duration.ticks)
        val viaProbe = MediaImporter.probe(file, file.name, "Sunrise Drive", "audio/wav")
        assertNotNull(viaProbe)
        assertEquals(item.duration.ticks, viaProbe!!.duration.ticks)
    }

    private fun writeTone(file: File, seconds: Double) {
        val rate = 22_050
        val n = (seconds * rate).toInt()
        DataOutputStream(FileOutputStream(file).buffered()).use { out ->
            fun le32(v: Int) = out.write(byteArrayOf(v.toByte(), (v shr 8).toByte(), (v shr 16).toByte(), (v shr 24).toByte()))
            fun le16(v: Int) = out.write(byteArrayOf(v.toByte(), (v shr 8).toByte()))
            out.writeBytes("RIFF"); le32(36 + n * 2); out.writeBytes("WAVEfmt "); le32(16); le16(1); le16(1)
            le32(rate); le32(rate * 2); le16(2); le16(16)
            out.writeBytes("data"); le32(n * 2)
            for (i in 0 until n) {
                val v = sin(2 * PI * 440.0 * i / rate) * 0.2
                le16((v * 32767).toInt().coerceIn(-32768, 32767))
            }
        }
    }
}
