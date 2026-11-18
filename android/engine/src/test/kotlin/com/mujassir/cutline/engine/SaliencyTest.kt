package com.mujassir.cutline.engine

import android.graphics.Bitmap
import android.graphics.Color
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class SaliencyTest {
    @Test
    fun subjectCentre_findsHighContrastBlobOffCentre() {
        val bmp = Bitmap.createBitmap(128, 128, Bitmap.Config.ARGB_8888)
        val px = IntArray(128 * 128) { Color.rgb(30, 30, 30) }
        // High-contrast checker in the lower-right quadrant.
        for (y in 72 until 120) for (x in 72 until 120) {
            px[y * 128 + x] = if ((x / 2 + y / 2) % 2 == 0) Color.WHITE else Color.BLACK
        }
        bmp.setPixels(px, 0, 128, 0, 0, 128, 128)
        val c = Saliency.subjectCentre(bmp)
        assertNotNull(c)
        assertTrue("x=${c!!.first}", c.first > 0.5)
        assertTrue("y=${c.second}", c.second > 0.5)
        bmp.recycle()
    }

    @Test
    fun subjectCentre_flatFrame_returnsNull() {
        val bmp = Bitmap.createBitmap(64, 64, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.GRAY) }
        assertNull(Saliency.subjectCentre(bmp))
        bmp.recycle()
    }
}
