package com.mujassir.cutline.engine

import android.graphics.Bitmap
import android.graphics.Color
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class SubjectMaskTest {
    @Test
    fun fromFaces_withoutFaces_drawsCentrePrior() {
        val frame = Bitmap.createBitmap(64, 64, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.GRAY) }
        val mask = SubjectMask.fromFaces(frame, 32, 32)
        assertEquals(32, mask.width)
        assertEquals(32, mask.height)
        // Centre should be brighter than a corner.
        val centre = Color.red(mask.getPixel(16, 13))
        val corner = Color.red(mask.getPixel(0, 0))
        assertTrue("centre=$centre corner=$corner", centre > corner)
        frame.recycle()
        mask.recycle()
    }
}
