package com.mujassir.cutline.app.editor

import android.content.Context
import android.view.SurfaceView
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.CompositionPlayer
import com.mujassir.cutline.core.MediaTime
import com.mujassir.cutline.core.Project
import com.mujassir.cutline.core.ProjectStore
import com.mujassir.cutline.engine.CompositionBuilder
import com.mujassir.cutline.engine.OverlayRenderer
import com.mujassir.cutline.engine.RenderToggles

/** The editor's preview (PRV). An interface so the UI can be tested without a media pipeline. */
interface PreviewPlayer {
    val toggles: RenderToggles
    /** Overlay renderer of the current composition (live text drag override). */
    val overlay: OverlayRenderer?
    val position: MediaTime
    val isPlaying: Boolean
    /** Rebuilds the preview for an edited project, keeping the playhead. */
    fun setProject(project: Project, at: MediaTime)
    fun play()
    fun pause()
    fun seek(time: MediaTime)
    /** PRV-9: preview-only speed, pitch kept. */
    fun setRate(rate: Float)
    fun attach(surface: SurfaceView)
    fun detach(surface: SurfaceView)
    fun release()
}

/** Test and placeholder player: keeps time with the system clock, draws nothing. */
class ClockPlayer : PreviewPlayer {
    override val toggles = RenderToggles()
    override val overlay: OverlayRenderer? = null
    private var base = MediaTime.ZERO
    private var startedAt = 0L
    private var rate = 1f
    override var isPlaying = false
        private set
    override val position: MediaTime
        get() = if (!isPlaying) base else base + MediaTime.seconds((System.nanoTime() - startedAt) / 1e9 * rate)

    override fun setProject(project: Project, at: MediaTime) { base = at }
    override fun play() { if (!isPlaying) { startedAt = System.nanoTime(); isPlaying = true; toggles.animate.set(true) } }
    override fun pause() { base = position; isPlaying = false; toggles.animate.set(false) }
    override fun seek(time: MediaTime) { base = time; startedAt = System.nanoTime() }
    override fun setRate(rate: Float) { base = position; startedAt = System.nanoTime(); this.rate = rate }
    override fun attach(surface: SurfaceView) {}
    override fun detach(surface: SurfaceView) {}
    override fun release() {}
}

/** Media3 CompositionPlayer showing the same composition the export renders (EXP-7). */
@UnstableApi
class CompositionPreviewPlayer(private val context: Context, store: ProjectStore) : PreviewPlayer {
    override val toggles = RenderToggles()
    private val builder = CompositionBuilder(store, toggles)
    private var player: CompositionPlayer? = null
    private var surface: SurfaceView? = null
    override var overlay: OverlayRenderer? = null
        private set
    private var rate = 1f

    override val position: MediaTime
        get() = player?.let { MediaTime(it.currentPosition * MediaTime.TIMESCALE / 1000) } ?: MediaTime.ZERO

    override val isPlaying: Boolean get() = player?.isPlaying == true

    override fun setProject(project: Project, at: MediaTime) {
        val built = runCatching { builder.build(project, 720, preview = true) }.getOrNull() ?: return
        overlay = built.overlay
        val wasPlaying = isPlaying
        // A Surface takes one producer, so the old player lets go of it first.
        val old = player
        surface?.let { old?.clearVideoSurfaceView(it) }
        old?.release()
        val p = CompositionPlayer.Builder(context).build()
        p.setComposition(built.composition)
        p.playbackParameters = PlaybackParameters(rate)
        surface?.let { p.setVideoSurfaceView(it) }
        p.prepare()
        p.seekTo(at.millis)
        p.playWhenReady = wasPlaying
        player = p
    }

    override fun play() {
        toggles.animate.set(true)
        player?.play()
    }

    override fun pause() {
        player?.pause()
        toggles.animate.set(false)
        // Redraw the paused frame at rest (PRV-3).
        player?.let { if (it.playbackState == Player.STATE_READY) it.seekTo(it.currentPosition) }
    }

    override fun seek(time: MediaTime) { player?.seekTo(time.millis.coerceAtLeast(0)) }

    override fun setRate(rate: Float) {
        this.rate = rate
        player?.playbackParameters = PlaybackParameters(rate)
    }

    override fun attach(surface: SurfaceView) {
        this.surface = surface
        player?.setVideoSurfaceView(surface)
    }

    override fun detach(surface: SurfaceView) {
        if (this.surface === surface) {
            player?.clearVideoSurfaceView(surface)
            this.surface = null
        }
    }

    override fun release() {
        player?.release()
        player = null
    }
}
