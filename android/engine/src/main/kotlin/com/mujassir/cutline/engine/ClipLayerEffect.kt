package com.mujassir.cutline.engine

import android.content.Context
import android.opengl.GLES20
import androidx.media3.common.util.GlProgram
import androidx.media3.common.util.GlUtil
import androidx.media3.common.util.Size as MSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BaseGlShaderProgram
import androidx.media3.effect.GlEffect
import androidx.media3.effect.GlShaderProgram
import com.mujassir.cutline.core.CanvasBackground
import com.mujassir.cutline.core.ColorAdjustments
import com.mujassir.cutline.core.render.FilterLooks
import com.mujassir.cutline.core.render.LayerAnimation
import com.mujassir.cutline.core.render.QuadVertex
import java.nio.ByteBuffer

/** What one clip layer draws at a moment (computed on the CPU, IMPLEMENTATION §8.2–8.5). */
data class LayerFrame(
    /** Clip quad (TL, TR, BL, BR). Empty = draw nothing. */
    val quad: List<QuadVertex>,
    /** Fill quad for the blurred background (§8.1 step 2), or null for a colour background. */
    val backgroundQuad: List<QuadVertex>?,
    val animation: LayerAnimation,
    val adjustments: ColorAdjustments,
    val filterID: String?,
    val filterIntensity: Double,
    /** Clip-local time in seconds (glitch noise). */
    val time: Double,
)

/**
 * Draws one main-track clip onto the canvas: the blurred background, then the clip with its
 * geometry, adjustments, filter look, vignette and animation (port of Shaders.metal, §8.3).
 * The output is the full canvas, so every item in the sequence has the same size.
 */
@UnstableApi
class ClipLayerEffect(
    private val canvasW: Int,
    private val canvasH: Int,
    private val background: CanvasBackground,
    /** Frame parameters for a presentation time (µs) and the input frame size. */
    private val frameAt: (Long, Int, Int) -> LayerFrame,
) : GlEffect {
    override fun toGlShaderProgram(context: Context, useHdr: Boolean): GlShaderProgram =
        ClipLayerProgram(canvasW, canvasH, background, frameAt)

    override fun isNoOp(inputWidth: Int, inputHeight: Int) = false
}

@UnstableApi
private class ClipLayerProgram(
    private val canvasW: Int,
    private val canvasH: Int,
    private val background: CanvasBackground,
    private val frameAt: (Long, Int, Int) -> LayerFrame,
) : BaseGlShaderProgram(false, 1) {
    private val layer = GlProgram(VERTEX, LAYER_FRAGMENT)
    private val blur = GlProgram(VERTEX, BLUR_FRAGMENT)
    private var inputW = 1
    private var inputH = 1
    private var lutTexture = -1
    private var lutFilter: String? = null
    // Small buffers for the blurred background (a quarter of the canvas).
    private val smallW = (canvasW / 4).coerceAtLeast(2)
    private val smallH = (canvasH / 4).coerceAtLeast(2)
    private var smallTex = IntArray(2) { -1 }
    private var smallFbo = IntArray(2) { -1 }

    override fun configure(inputWidth: Int, inputHeight: Int): MSize {
        inputW = inputWidth; inputH = inputHeight
        return MSize(canvasW, canvasH)
    }

    override fun drawFrame(inputTexId: Int, presentationTimeUs: Long) {
        val f = frameAt(presentationTimeUs, inputW, inputH)
        val out = IntArray(1).also { GLES20.glGetIntegerv(GLES20.GL_FRAMEBUFFER_BINDING, it, 0) }[0]
        val bg = background
        if (bg is CanvasBackground.Color) {
            GLES20.glClearColor(bg.color.r.toFloat(), bg.color.g.toFloat(), bg.color.b.toFloat(), 1f)
        } else {
            GLES20.glClearColor(0f, 0f, 0f, 1f)
        }
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
        if (f.quad.isEmpty()) return
        f.backgroundQuad?.let { drawBlurredBackground(inputTexId, it, out) }
        GLES20.glEnable(GLES20.GL_BLEND)
        GLES20.glBlendFunc(GLES20.GL_ONE, GLES20.GL_ONE_MINUS_SRC_ALPHA)
        drawLayer(inputTexId, f.quad, f, canvasW, canvasH, brightnessOverride = null)
        GLES20.glDisable(GLES20.GL_BLEND)
        GlUtil.checkGlError()
    }

    /** §8.1 step 2: quarter-size fill at brightness 0.8, Gaussian blur (σ = small width ÷ 18), stretched. */
    private fun drawBlurredBackground(input: Int, quad: List<QuadVertex>, outFbo: Int) {
        ensureSmallBuffers()
        GlUtil.focusFramebufferUsingCurrentContext(smallFbo[0], smallW, smallH)
        GLES20.glClearColor(0f, 0f, 0f, 1f); GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
        val plain = LayerFrame(quad, null, LayerAnimation(), ColorAdjustments(), null, 0.0, 0.0)
        drawLayer(input, quad, plain, smallW, smallH, brightnessOverride = 0.8f)
        val sigma = smallW / 18f
        // Horizontal pass into buffer 1, vertical pass to the output.
        GlUtil.focusFramebufferUsingCurrentContext(smallFbo[1], smallW, smallH)
        drawBlur(smallTex[0], 1f / smallW, 0f, sigma)
        GlUtil.focusFramebufferUsingCurrentContext(outFbo, canvasW, canvasH)
        drawBlur(smallTex[1], 0f, 1f / smallH, sigma)
    }

    private fun drawBlur(tex: Int, dx: Float, dy: Float, sigma: Float) {
        blur.use()
        blur.setBufferAttribute("aPosition", floatArrayOf(-1f, 1f, 0f, 1f, 1f, 1f, 0f, 1f, -1f, -1f, 0f, 1f, 1f, -1f, 0f, 1f), 4)
        // Texture coordinates for a texture rendered by us (origin bottom-left).
        blur.setBufferAttribute("aUv", floatArrayOf(0f, 1f, 0f, 1f, 1f, 1f, 0f, 1f, 0f, 0f, 0f, 1f, 1f, 0f, 0f, 1f), 4)
        blur.setSamplerTexIdUniform("uTex", tex, 0)
        blur.setFloatsUniform("uStep", floatArrayOf(dx, dy))
        blur.setFloatUniform("uSigma", sigma)
        blur.bindAttributesAndUniforms()
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
    }

    private fun drawLayer(input: Int, quad: List<QuadVertex>, f: LayerFrame, w: Int, h: Int, brightnessOverride: Float?) {
        layer.use()
        val pos = FloatArray(16); val uv = FloatArray(16); val local = FloatArray(16)
        quad.forEachIndexed { i, v ->
            pos[i * 4] = v.px; pos[i * 4 + 1] = v.py; pos[i * 4 + 3] = 1f
            // LayerGeometry UVs have their origin top-left; GL textures bottom-left.
            uv[i * 4] = v.u; uv[i * 4 + 1] = 1f - v.v; uv[i * 4 + 3] = 1f
            local[i * 4] = v.lx; local[i * 4 + 1] = v.ly; local[i * 4 + 3] = 1f
        }
        layer.setBufferAttribute("aPosition", pos, 4)
        layer.setBufferAttribute("aUv", uv, 4)
        layer.setBufferAttribute("aLocal", local, 4)
        layer.setSamplerTexIdUniform("uTex", input, 0)
        val a = f.adjustments
        val anim = f.animation
        layer.setFloatsUniform("uTexel", floatArrayOf(1f / inputW, 1f / inputH))
        layer.setFloatsUniform("uCanvas", floatArrayOf(w.toFloat(), h.toFloat()))
        layer.setFloatsUniform("uAdjustA", floatArrayOf(a.exposure.toFloat(), a.contrast.toFloat(), a.saturation.toFloat(), a.warmth.toFloat()))
        layer.setFloatsUniform("uAdjustB", floatArrayOf(a.highlights.toFloat(), a.shadows.toFloat(), a.vignette.toFloat(), a.sharpen.toFloat()))
        layer.setFloatUniform("uOpacity", anim.opacity.toFloat())
        layer.setFloatUniform("uBrightness", brightnessOverride ?: anim.brightness.toFloat())
        layer.setFloatUniform("uBlur", anim.blurRadius.toFloat())
        layer.setFloatUniform("uWipe", anim.wipeProgress.toFloat())
        layer.setFloatUniform("uGlitch", anim.glitch.toFloat())
        layer.setFloatUniform("uTime", f.time.toFloat())
        val filter = f.filterID?.takeIf { FilterLooks.look(it) != null && f.filterIntensity > 0.001 }
        if (filter != null) ensureLut(filter)
        layer.setFloatUniform("uFilterIntensity", if (filter != null) f.filterIntensity.toFloat() else 0f)
        layer.setSamplerTexIdUniform("uLut", if (filter != null) lutTexture else input, 1)
        layer.bindAttributesAndUniforms()
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
    }

    private fun ensureLut(id: String) {
        if (lutFilter == id && lutTexture >= 0) return
        if (lutTexture < 0) {
            val t = IntArray(1); GLES20.glGenTextures(1, t, 0); lutTexture = t[0]
        }
        val n = FilterLooks.LUT_SIZE
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, lutTexture)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_NEAREST)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_NEAREST)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexImage2D(GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA, n * n, n, 0, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE,
            ByteBuffer.wrap(FilterLooks.lutStrip(id)))
        lutFilter = id
    }

    private fun ensureSmallBuffers() {
        if (smallTex[0] >= 0) return
        for (i in 0..1) {
            smallTex[i] = GlUtil.createTexture(smallW, smallH, false)
            smallFbo[i] = GlUtil.createFboForTexture(smallTex[i])
        }
    }

    override fun release() {
        super.release()
        runCatching { layer.delete(); blur.delete() }
        if (lutTexture >= 0) runCatching { GlUtil.deleteTexture(lutTexture) }
        for (i in 0..1) {
            if (smallFbo[i] >= 0) runCatching { GlUtil.deleteFbo(smallFbo[i]) }
            if (smallTex[i] >= 0) runCatching { GlUtil.deleteTexture(smallTex[i]) }
        }
    }

    companion object {
        const val VERTEX = """
attribute vec4 aPosition;
attribute vec4 aUv;
attribute vec4 aLocal;
varying vec2 vUv;
varying vec2 vLocal;
void main() {
  gl_Position = vec4(aPosition.xy, 0.0, 1.0);
  vUv = aUv.xy;
  vLocal = aLocal.xy;
}
"""

        /** Shaders.metal, line for line where GLSL ES 1.0 allows (IMPLEMENTATION §8.3). */
        const val LAYER_FRAGMENT = """
precision highp float;
uniform sampler2D uTex;
uniform sampler2D uLut;
uniform vec2 uTexel;
uniform vec2 uCanvas;
uniform vec4 uAdjustA;   // exposure, contrast, saturation, warmth
uniform vec4 uAdjustB;   // highlights, shadows, vignette, sharpen
uniform float uOpacity;
uniform float uBrightness;
uniform float uBlur;
uniform float uWipe;
uniform float uGlitch;
uniform float uTime;
uniform float uFilterIntensity;
varying vec2 vUv;
varying vec2 vLocal;

float luma(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }

vec4 sampleBlur(vec2 uv) {
  if (uBlur < 0.5) return texture2D(uTex, uv);
  vec4 acc = texture2D(uTex, uv);
  for (int i = 1; i <= 12; i++) {
    float fi = float(i);
    float r = sqrt(fi / 12.0) * uBlur;
    float a = fi * 2.39996323;
    acc += texture2D(uTex, uv + vec2(cos(a), sin(a)) * r * uTexel);
  }
  return acc / 13.0;
}

vec3 lut(vec3 c) {
  float n = 33.0;
  vec3 s = clamp(c, 0.0, 1.0) * (n - 1.0);
  float b0 = floor(s.b);
  float b1 = min(b0 + 1.0, n - 1.0);
  float fb = s.b - b0;
  // Strip layout: x = r + b * n, y = g. Bilinear in r/g by hand, linear in b.
  vec2 rg = s.rg;
  vec2 r0g0 = floor(rg);
  vec2 f = rg - r0g0;
  vec2 r1g1 = min(r0g0 + 1.0, vec2(n - 1.0));
  vec2 size = vec2(n * n, n);
  vec3 c0, c1;
  {
    vec3 a = texture2D(uLut, (vec2(r0g0.x + b0 * n, r0g0.y) + 0.5) / size).rgb;
    vec3 b = texture2D(uLut, (vec2(r1g1.x + b0 * n, r0g0.y) + 0.5) / size).rgb;
    vec3 cc = texture2D(uLut, (vec2(r0g0.x + b0 * n, r1g1.y) + 0.5) / size).rgb;
    vec3 d = texture2D(uLut, (vec2(r1g1.x + b0 * n, r1g1.y) + 0.5) / size).rgb;
    c0 = mix(mix(a, b, f.x), mix(cc, d, f.x), f.y);
  }
  {
    vec3 a = texture2D(uLut, (vec2(r0g0.x + b1 * n, r0g0.y) + 0.5) / size).rgb;
    vec3 b = texture2D(uLut, (vec2(r1g1.x + b1 * n, r0g0.y) + 0.5) / size).rgb;
    vec3 cc = texture2D(uLut, (vec2(r0g0.x + b1 * n, r1g1.y) + 0.5) / size).rgb;
    vec3 d = texture2D(uLut, (vec2(r1g1.x + b1 * n, r1g1.y) + 0.5) / size).rgb;
    c1 = mix(mix(a, b, f.x), mix(cc, d, f.x), f.y);
  }
  return mix(c0, c1, fb);
}

void main() {
  vec2 uv = vUv;
  // 1. Glitch slices.
  if (uGlitch > 0.001) {
    float slice = floor(gl_FragCoord.y / uCanvas.y * 24.0);
    float n = fract(sin(slice * 91.7 + floor(uTime * 30.0) * 13.3) * 43758.5453);
    uv.x += (n - 0.5) * 0.08 * uGlitch * step(0.6, n);
  }
  // 2. Sample (with the disc blur).
  vec4 s = sampleBlur(uv);
  vec3 c = s.rgb;
  // 3. Glitch colour split.
  if (uGlitch > 0.001) {
    c.r = sampleBlur(uv + vec2(0.012 * uGlitch, 0.0)).r;
    c.b = sampleBlur(uv - vec2(0.012 * uGlitch, 0.0)).b;
  }
  // 4. Sharpen.
  if (uAdjustB.w > 0.001) {
    vec3 m = (texture2D(uTex, uv + vec2(uTexel.x, 0.0)).rgb + texture2D(uTex, uv - vec2(uTexel.x, 0.0)).rgb
            + texture2D(uTex, uv + vec2(0.0, uTexel.y)).rgb + texture2D(uTex, uv - vec2(0.0, uTexel.y)).rgb) * 0.25;
    c += (c - m) * uAdjustB.w * 1.5;
  }
  // 5. Adjust.
  c *= pow(2.0, uAdjustA.x * 1.5);
  float l = luma(c);
  float hw = smoothstep(0.45, 1.0, l);
  float sw = 1.0 - smoothstep(0.0, 0.55, l);
  c += c * uAdjustB.x * 0.45 * hw;
  c += uAdjustB.y * 0.35 * sw;
  c = (c - 0.5) * (1.0 + uAdjustA.y * 0.8) + 0.5;
  c = mix(vec3(luma(c)), c, 1.0 + uAdjustA.z);
  c.r += uAdjustA.w * 0.08;
  c.b -= uAdjustA.w * 0.08;
  c = clamp(c, 0.0, 1.0);
  // 6. Filter look.
  if (uFilterIntensity > 0.001) c = mix(c, lut(c), uFilterIntensity);
  // 7. Vignette.
  float v = smoothstep(0.85, 0.2, length(vLocal - 0.5) * 1.2);
  c *= mix(1.0, v, uAdjustB.z);
  // 8. Brightness and opacity.
  c *= uBrightness;
  float alpha = s.a * uOpacity;
  // 10. Wipe.
  if (uWipe >= 0.0) {
    float x = gl_FragCoord.x / uCanvas.x;
    alpha *= 1.0 - smoothstep(uWipe - 0.02, uWipe + 0.02, x);
  }
  gl_FragColor = vec4(c * alpha, alpha);
}
"""

        const val BLUR_FRAGMENT = """
precision highp float;
uniform sampler2D uTex;
uniform vec2 uStep;
uniform float uSigma;
varying vec2 vUv;
varying vec2 vLocal;
void main() {
  vec4 acc = vec4(0.0);
  float total = 0.0;
  for (int i = -12; i <= 12; i++) {
    float x = float(i) * max(uSigma, 1.0) / 4.0;
    float w = exp(-0.5 * (x * x) / (uSigma * uSigma));
    acc += texture2D(uTex, vUv + uStep * x) * w;
    total += w;
  }
  gl_FragColor = vec4((acc / total).rgb, 1.0);
}
"""
    }
}
