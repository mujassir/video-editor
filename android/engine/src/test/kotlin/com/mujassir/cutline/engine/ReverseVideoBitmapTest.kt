package com.mujassir.cutline.engine

import android.graphics.Bitmap
import android.graphics.Color
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class ReverseVideoBitmapTest {
    @Test
    fun rgbaToNV12_writesYPlaneForSolidColor() {
        val bmp = Bitmap.createBitmap(4, 4, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.WHITE) }
        val out = ByteArray(4 * 4 * 3 / 2)
        ReverseVideo.rgbaToNV12(bmp, out, 4, 4)
        assertTrue(out[0].toInt() and 0xFF > 200)
        bmp.recycle()
    }
}
