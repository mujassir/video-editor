package com.mujassir.cutline.engine

import com.mujassir.cutline.core.NoiseReduction
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.sin
import kotlin.math.sqrt

/** Port of iOS EngineTests noise-reduction suite (IMPLEMENTATION §9.4 / DNS-3 / DNS-6). */
class NoiseReducerTest {
    private fun signal(seconds: Double, sampleRate: Double = 48_000.0): Triple<FloatArray, IntRange, IntRange> {
        var seed = 42u
        fun noise(): Float {
            seed = seed * 1_664_525u + 1_013_904_223u
            return seed.toFloat() / UInt.MAX_VALUE.toFloat() * 2f - 1f
        }
        val count = (seconds * sampleRate).toInt()
        val out = FloatArray(count)
        val block = (0.5 * sampleRate).toInt()
        for (i in 0 until count) {
            val hiss = 0.03f * noise()
            val toneOn = (i / block) % 2 == 1
            val tone = if (toneOn) 0.3f * sin(2.0 * PI * 300.0 * i / sampleRate).toFloat() else 0f
            out[i] = hiss + tone
        }
        val hiss = (2 * block + block / 4) until (2 * block + 3 * block / 4)
        val tone = (3 * block + block / 4) until (3 * block + 3 * block / 4)
        return Triple(out, hiss, tone)
    }

    private fun rmsDB(x: FloatArray, range: IntRange): Float {
        var sum = 0.0
        for (i in range) sum += x[i].toDouble() * x[i]
        val rms = sqrt(sum / range.count())
        return (20 * log10(max(rms, 1e-9))).toFloat()
    }

    @Test
    fun hissDropsAndTheToneStays_atEveryLevel() {
        for (level in NoiseReduction.entries) {
            val (mix, hiss, tone) = signal(4.0)
            val out = NoiseReducer.reduce(listOf(mix), level)[0]
            assertEquals(mix.size, out.size)
            val hissDrop = rmsDB(mix, hiss) - rmsDB(out, hiss)
            val toneChange = abs(rmsDB(mix, tone) - rmsDB(out, tone))
            assertTrue("hiss reduced by $hissDrop dB at $level", hissDrop > 8f)
            assertTrue("tone changed by $toneChange dB at $level", toneChange < 1.5f)
        }
    }

    @Test
    fun strongerLevelsRemoveMore() {
        val (mix, hiss, _) = signal(4.0)
        val drops = NoiseReduction.entries.map { level ->
            val out = NoiseReducer.reduce(listOf(mix), level)[0]
            rmsDB(mix, hiss) - rmsDB(out, hiss)
        }
        assertTrue("drops=$drops", drops[0] < drops[1] && drops[1] < drops[2])
    }

    @Test
    fun DNS_6_quietStartDoesNotStopNoiseRemoval() {
        for (level in NoiseReduction.entries) {
            val (sig, hiss, tone) = signal(4.0)
            val quiet = FloatArray(24_000)
            val soft = FloatArray(24_000) { i -> sig[i] * 0.1f }
            val mix = FloatArray(quiet.size + soft.size + sig.size).also { out ->
                System.arraycopy(quiet, 0, out, 0, quiet.size)
                System.arraycopy(soft, 0, out, quiet.size, soft.size)
                System.arraycopy(sig, 0, out, quiet.size + soft.size, sig.size)
            }
            val out = NoiseReducer.reduce(listOf(mix), level)[0]
            val shift = quiet.size + soft.size
            val h = (hiss.first + shift)..(hiss.last + shift)
            val t = (tone.first + shift)..(tone.last + shift)
            val hissDrop = rmsDB(mix, h) - rmsDB(out, h)
            val toneChange = abs(rmsDB(mix, t) - rmsDB(out, t))
            assertTrue("hiss reduced by $hissDrop dB at $level after quiet start", hissDrop > 8f)
            assertTrue("tone changed by $toneChange dB at $level after quiet start", toneChange < 1.5f)
        }
    }

    @Test
    fun DNS_6_fingerprintSkipsPaddingAndSilence() {
        val length = 48_000 * 3
        val frames = (length + 2 * NoiseReducer.FRAME_SIZE + NoiseReducer.HOP - NoiseReducer.FRAME_SIZE) /
            NoiseReducer.HOP + 1
        val energies = FloatArray(frames) { f ->
            val inside = f >= NoiseReducer.FRAME_SIZE / NoiseReducer.HOP && f <= length / NoiseReducer.HOP
            when {
                !inside || f <= 98 -> 0f
                f % 7 == 0 -> 1f
                else -> 50f
            }
        }
        val picked = NoiseReducer.noiseFrames(energies, length)
        assertTrue(picked.isNotEmpty())
        assertTrue("picked ${picked.map { energies[it] }}", picked.all { energies[it] == 1f })
    }

    @Test
    fun DNS_3_onlyCurrentFilesAreReused() {
        assertEquals("nr2-medium-A1B2.wav", NoiseReducer.fileName(NoiseReduction.MEDIUM, "A1B2"))
        assertTrue(NoiseReducer.isCurrent(NoiseReducer.fileName(NoiseReduction.HIGH, "x")))
        assertFalse(NoiseReducer.isCurrent("nr-medium-A1B2.m4a"))
    }
}
