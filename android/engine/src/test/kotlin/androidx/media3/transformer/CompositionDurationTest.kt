// In Media3's package so the test can call the package-private getPresentationDurationUs(),
// the method CompositionPlayer uses to add up each sequence's length.
package androidx.media3.transformer

import androidx.media3.common.util.UnstableApi
import com.mujassir.cutline.core.AudioClip
import com.mujassir.cutline.core.MediaItem
import com.mujassir.cutline.core.MediaKind
import com.mujassir.cutline.core.MediaTime
import com.mujassir.cutline.core.MediaTimeRange
import com.mujassir.cutline.core.Project
import com.mujassir.cutline.core.ProjectStore
import com.mujassir.cutline.core.Size
import com.mujassir.cutline.core.VideoClip
import com.mujassir.cutline.engine.CompositionBuilder
import com.mujassir.cutline.engine.RenderToggles
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.nio.file.Files

@UnstableApi
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class CompositionDurationTest {
    private fun s(v: Double) = MediaTime.seconds(v)

    /** Regression: adding a video clip crashed CompositionPlayer.setComposition (unset item length). */
    @Test fun `IMP-1 PRV-1 a video clip and music give the preview a set length`() {
        val store = ProjectStore(Files.createTempDirectory("cutline").toFile())
        val video = MediaItem(kind = MediaKind.VIDEO, fileName = "clip.mp4", naturalSize = Size(1080.0, 1920.0),
            duration = s(10.0), hasAudio = true)
        val song = MediaItem(kind = MediaKind.AUDIO, fileName = "song.m4a", naturalSize = Size.ZERO,
            duration = s(30.0), hasAudio = true)
        val project = Project(
            name = "Crash",
            media = listOf(video, song),
            // 2 s to 6 s of the video at 2×: 2 s on the timeline.
            clips = listOf(VideoClip(mediaID = video.id, kind = MediaKind.VIDEO, sourceRange = MediaTimeRange(s(2.0), s(4.0)), speed = 2.0)),
            audioClips = listOf(AudioClip(mediaID = song.id, role = AudioClip.Role.MUSIC,
                sourceRange = MediaTimeRange(MediaTime.ZERO, s(9.0)), start = MediaTime.ZERO)),
        )

        val built = CompositionBuilder(store, RenderToggles()).build(project, shortEdge = 720, preview = true)
        val lengths = built.composition.sequences.map { seq -> seq.editedMediaItems.sumOf { it.presentationDurationUs } }

        assertEquals(listOf(2_000_000L, 9_000_000L), lengths)
    }
}
