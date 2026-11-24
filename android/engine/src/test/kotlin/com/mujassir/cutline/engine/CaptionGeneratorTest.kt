package com.mujassir.cutline.engine

import com.mujassir.cutline.core.MediaTime
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CaptionGeneratorTest {
    @Test
    fun demoWords_coverDuration() {
        val words = CaptionGenerator.demoWords(MediaTime.seconds(7.0))
        assertEquals(7, words.size)
        assertEquals("Welcome", words.first().text)
        assertEquals("phone", words.last().text)
        assertTrue(words.last().range.end.seconds >= 3.5)
    }

    @Test
    fun segments_usesCoreGrouping() {
        val words = CaptionGenerator.demoWords(MediaTime.seconds(10.0))
        val segs = CaptionGenerator.segments(words)
        assertTrue(segs.isNotEmpty())
        assertEquals(words.size, segs.sumOf { it.words.size })
        assertTrue(segs.all { it.words.size <= 5 })
    }

    @Test
    fun speechMix_hasEnergy_rejectsSilence() {
        assertTrue(!SpeechMix.hasEnergy(FloatArray(1000) { 0f }))
        assertTrue(SpeechMix.hasEnergy(FloatArray(1000) { 0.2f }))
    }
}
