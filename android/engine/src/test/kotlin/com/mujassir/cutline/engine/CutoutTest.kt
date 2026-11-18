package com.mujassir.cutline.engine

import com.mujassir.cutline.core.BackgroundReplacement
import com.mujassir.cutline.core.RGBAColor
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pure §10.4 maths — no Robolectric (avoids flaky android-all downloads on CI). */
class CutoutTest {
    @Test
    fun softEdge_smoothstepsBetween15And85() {
        assertEquals(0f, Cutout.softEdge(0f), 1e-5f)
        assertEquals(0f, Cutout.softEdge(0.15f), 1e-5f)
        assertEquals(1f, Cutout.softEdge(0.85f), 1e-5f)
        assertEquals(1f, Cutout.softEdge(1f), 1e-5f)
        val mid = Cutout.softEdge(0.5f)
        assertTrue("mid=$mid", mid > 0.4f && mid < 0.6f)
    }

    @Test
    fun transparent_zerosAlphaOutsidePerson() {
        val fg = floatArrayOf(1f, 0f, 0f)
        val bg = floatArrayOf(0f, 1f, 0f)
        val inside = Cutout.mix(fg, bg, 1f, 1f, BackgroundReplacement.Transparent)
        assertEquals(1f, inside[0], 1e-4f)
        assertEquals(1f, inside[3], 1e-4f)
        val outside = Cutout.mix(fg, bg, 1f, 0f, BackgroundReplacement.Transparent)
        assertEquals(0f, outside[0], 1e-4f)
        assertEquals(0f, outside[3], 1e-4f)
    }

    @Test
    fun color_mixesSolidOutsidePerson() {
        val fg = floatArrayOf(1f, 0f, 0f)
        val green = BackgroundReplacement.Color(RGBAColor(0.0, 1.0, 0.0, 1.0))
        val outside = Cutout.mix(fg, Cutout.rgba(green.color), 1f, 0f, green)
        assertEquals(0f, outside[0], 1e-4f)
        assertEquals(1f, outside[1], 1e-4f)
        assertEquals(1f, outside[3], 1e-4f)
    }
}
