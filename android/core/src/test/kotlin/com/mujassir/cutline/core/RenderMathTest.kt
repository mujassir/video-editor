package com.mujassir.cutline.core

import com.mujassir.cutline.core.render.FilterLooks
import com.mujassir.cutline.core.render.LayerAnimation
import com.mujassir.cutline.core.render.LayerGeometry
import com.mujassir.cutline.core.render.Rgb
import com.mujassir.cutline.core.render.Vec2
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class RenderMathTest {
    private val landscape = MediaItem(kind = MediaKind.VIDEO, fileName = "v.mov", naturalSize = Size(1920.0, 1080.0),
        duration = MediaTime.seconds(5), hasAudio = true)
    private val canvas = Size(1080.0, 1920.0)

    @Test fun `CNV-2 fit keeps the whole frame, fill covers the canvas`() {
        val fit = LayerGeometry.quad(landscape, ClipTransform(fit = ContentFit.FIT), 0, canvas)
        assertEquals(-1f, fit[0].px, 1e-4f); assertEquals(1f, fit[1].px, 1e-4f)           // full width
        val h = (fit[0].py - fit[2].py) / 2                                                // NDC height / 2
        assertEquals(1080.0 * (1080.0 / 1920.0) / 1920.0, h.toDouble(), 1e-4)
        val fill = LayerGeometry.quad(landscape, ClipTransform(fit = ContentFit.FILL), 0, canvas)
        assertEquals(1f, fill[0].py, 1e-4f); assertEquals(-1f, fill[2].py, 1e-4f)          // full height
        assertTrue(fill[0].px < -1f)
    }

    @Test fun `ANM unrotate and source turns map UVs to the raw frame`() {
        assertEquals(Vec2(0.0, 1.0), LayerGeometry.unrotate(Vec2(0.0, 0.0), 1))
        val q = LayerGeometry.quad(landscape.copy(sourceQuarterTurns = 1), ClipTransform(), 1, canvas)
        assertEquals(0f, q[0].u, 1e-6f); assertEquals(1f, q[0].v, 1e-6f)
    }

    @Test fun `TRN fade dips to black in two halves`() {
        val out = LayerGeometry.transitionAnimation(TransitionKind.FADE, 0.25, incoming = false)
        assertEquals(0.5, out.brightness, 1e-9)
        val inc = LayerGeometry.transitionAnimation(TransitionKind.FADE, 0.75, incoming = true)
        assertEquals(1.0, inc.opacity, 0.0); assertEquals(0.5, inc.brightness, 1e-9)
    }

    @Test fun `ANM clip animation combines entrance, exit and combo`() {
        val anim = ClipAnimation(entrance = ClipEntrance.FADE, exit = ClipEntrance.FADE, inDuration = 1.0, outDuration = 1.0)
        assertEquals(0.5, LayerGeometry.clipAnimation(anim, 0.5, 4.0).opacity, 1e-9)
        assertEquals(1.0, LayerGeometry.clipAnimation(anim, 2.0, 4.0).opacity, 1e-9)
        assertEquals(0.25, LayerGeometry.clipAnimation(anim, 3.75, 4.0).opacity, 1e-9)
        // On a short clip In and Out each get at most half.
        assertEquals(0.5, LayerGeometry.clipAnimation(anim, 0.5, 2.0).opacity, 1e-9)
        val c = LayerGeometry.combine(LayerAnimation(scale = 2.0, opacity = 0.5), LayerAnimation(scale = 1.5, opacity = 0.5, wipeProgress = 0.3))
        assertEquals(3.0, c.scale, 1e-9); assertEquals(0.25, c.opacity, 1e-9); assertEquals(0.3, c.wipeProgress, 1e-9)
    }

    @Test fun `ANM-4 ken burns stays inside the zoom range`() {
        val start = LayerGeometry.photoMotion(PhotoMotion.KEN_BURNS, 0.0)
        val end = LayerGeometry.photoMotion(PhotoMotion.KEN_BURNS, 1.0)
        assertEquals(1.08, start.scale, 1e-9); assertEquals(1.28, end.scale, 1e-9)
        assertEquals(Vec2(-0.035, 0.025), start.offset)
    }

    @Test fun `FLT-1 twenty looks in panel order, exact formulas`() {
        assertEquals(20, FilterLooks.ALL.size)
        assertEquals(listOf("Vivid", "Warm", "Cool", "Cinema", "Film"), FilterLooks.ALL.take(5).map { it.name })
        val mono = FilterLooks.grade("mono", Rgb(1.0, 0.0, 0.0))
        assertEquals(0.2126, mono.r, 1e-9); assertEquals(mono.r, mono.b, 0.0)
        val punch = FilterLooks.grade("punch", Rgb(0.5, 0.5, 0.5))
        assertEquals(0.5, punch.g, 1e-9)
        assertEquals(33 * 33 * 33 * 4, FilterLooks.lutStrip("vivid").size)
    }

    @Test fun `ADJ neutral adjustments leave colours unchanged`() {
        val c = Rgb(0.3, 0.6, 0.9)
        val out = FilterLooks.adjust(c, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
        assertEquals(c.r, out.r, 1e-9); assertEquals(c.g, out.g, 1e-9); assertEquals(c.b, out.b, 1e-9)
    }
}
