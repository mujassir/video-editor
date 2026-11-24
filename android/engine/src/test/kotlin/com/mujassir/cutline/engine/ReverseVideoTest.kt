package com.mujassir.cutline.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pure REV-1 window / timestamp maths — no Robolectric. */
class ReverseVideoTest {
    @Test
    fun reversedPresentationTime_mapsSourceEndToNearZero() {
        val total = 4.0
        val fd = 1.0 / 30
        assertEquals(0.0, ReverseVideo.reversedPresentationTime(total - fd, total, fd), 1e-9)
        assertTrue(ReverseVideo.reversedPresentationTime(0.0, total, fd) > total - fd - 0.001)
    }

    @Test
    fun windows_coverTimelineNewestFirst() {
        val w = ReverseVideo.windows(2.5, window = 1.0)
        assertEquals(listOf(1.5 to 2.5, 0.5 to 1.5, 0.0 to 0.5), w)
    }

    @Test
    fun sampleTimesInWindow_areNewestFirst() {
        val times = ReverseVideo.sampleTimesInWindow(0.0, 0.1, 1.0 / 30)
        assertTrue(times.isNotEmpty())
        assertTrue(times.first() >= times.last())
        assertTrue(times.first() < 0.1)
    }

    @Test
    fun reverseFileName_matchesContractPrefix() {
        assertEquals("rev-clip.mov", MediaProcessing.reverseFileName("clip.mp4"))
    }
}
