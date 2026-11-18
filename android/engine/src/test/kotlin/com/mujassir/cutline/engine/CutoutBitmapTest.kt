package com.mujassir.cutline.engine

import android.graphics.Bitmap
import android.graphics.Color
import com.mujassir.cutline.core.BackgroundReplacement
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class CutoutBitmapTest {
    @Test
    fun applyMask_transparentKeepsOnlyPersonPixels() {
        val src = Bitmap.createBitmap(4, 4, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.RED) }
        val mask = Bitmap.createBitmap(4, 4, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.BLACK) }
        for (y in 0 until 4) for (x in 2 until 4) mask.setPixel(x, y, Color.WHITE)
        val out = Cutout.applyMask(src, mask, BackgroundReplacement.Transparent)
        assertEquals(0, Color.alpha(out.getPixel(0, 0)))
        assertEquals(255, Color.alpha(out.getPixel(3, 0)))
        assertEquals(255, Color.red(out.getPixel(3, 0)))
    }
}
