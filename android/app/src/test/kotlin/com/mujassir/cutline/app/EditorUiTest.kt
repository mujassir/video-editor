package com.mujassir.cutline.app

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.github.takahirom.roborazzi.captureRoboImage
import com.mujassir.cutline.app.editor.ClockPlayer
import com.mujassir.cutline.app.ui.CutlineTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.File
import java.nio.file.Files

/**
 * UI scenarios on the JVM (Robolectric), with screenshots in app/build/screens. Uses the clock
 * player: the media pipeline itself needs a device.
 */
@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
abstract class CutlineUiTest {
    @get:Rule val rule = createComposeRule()
    protected val root: File = Files.createTempDirectory("cutline").toFile()
    private var launched = false

    protected fun launch() {
        if (launched) return
        rule.setContent { CutlineTheme { CutlineApp(sampleMedia = true, rootDir = root, playerFactory = { ClockPlayer() }) } }
        launched = true
    }

    protected fun shot(name: String) = rule.onRoot().captureRoboImage("build/screens/$name.png")

    protected fun waitFor(tag: String, timeout: Long = 15_000) =
        rule.waitUntil(timeout) { rule.onAllNodesWithTag(tag).fetchSemanticsNodes().isNotEmpty() }

    protected fun count(prefix: String) = (0 until 50).count { rule.onAllNodesWithTag("$prefix$it").fetchSemanticsNodes().isNotEmpty() }

    protected fun waitGone(tag: String, timeout: Long = 15_000) =
        rule.waitUntil(timeout) { rule.onAllNodesWithTag(tag).fetchSemanticsNodes().isEmpty() }

    /** New project with the three sample photos on the timeline. */
    protected fun openProjectWithSamples() {
        launch()
        rule.onNodeWithTag("projects.new").performClick()
        waitFor("timeline.add")
        rule.onNodeWithTag("timeline.add").performClick()
        waitFor("add.samples")
        rule.onNodeWithTag("add.samples").performClick()
        rule.waitUntil(20_000) { count("clip.") == 3 }
        rule.waitUntil(20_000) { rule.onAllNodesWithTag("busy").fetchSemanticsNodes().isEmpty() }
    }

    /** Select the first photo clip and open a photo tool panel. */
    protected fun openPhotoTool(tool: String, panel: String) {
        openProjectWithSamples()
        rule.onNodeWithTag("clip.0").performClick()
        waitFor("tool.Duration")
        rule.onNodeWithTag(tool).performScrollTo().performClick()
        waitFor(panel)
    }
}

@Config(sdk = [35], qualifiers = "w411dp-h891dp-xxhdpi")
class PhoneUiTest : CutlineUiTest() {
    @Test fun `LIB-1 library, new project, sample clips and the main toolbar`() {
        launch()
        waitFor("projects.new")
        shot("phone-01-library")
        openProjectWithSamples()
        shot("phone-02-editor")
        // TBR-1 with content: Music, Watermark, Text, Intro, Outro (Captions needs a video clip).
        for (t in listOf("tool.Music", "tool.Watermark", "tool.Text", "tool.Intro", "tool.Outro")) rule.onNodeWithTag(t).assertIsDisplayed()
        assertEquals(0, rule.onAllNodesWithTag("tool.Captions").fetchSemanticsNodes().size)
        rule.onNodeWithTag("editor.export").assertIsDisplayed()
    }

    @Test fun `TBR-3 photo tools, Filters panel and undo`() {
        openProjectWithSamples()
        rule.onNodeWithTag("clip.0").performClick()
        waitFor("tool.Duration")
        shot("phone-03-photo-tools")
        rule.onNodeWithTag("tool.Filters").performClick()
        waitFor("panel.Filters")
        rule.onNodeWithTag("filter.vivid").performClick()
        rule.waitForIdle()
        shot("phone-04-filters")
        rule.onNodeWithTag("panel.done").performClick()
        waitFor("editor.undo")
        rule.onNodeWithTag("editor.undo").performClick()
        rule.waitForIdle()
    }

    @Test fun `TXT-1 add text opens the edit panel`() {
        openProjectWithSamples()
        rule.onNodeWithTag("tool.Text").performClick()
        waitFor("panel.Text")
        waitFor("text.0")
        shot("phone-05-text")
    }

    @Test fun `TTL-1 opening slide is added as the first clip`() {
        openProjectWithSamples()
        rule.onNodeWithTag("tool.Intro").performClick()
        waitFor("panel.Opening Slide")
        rule.onNodeWithTag("titleStyle.ocean").performClick()
        shot("phone-06-intro")
        rule.onNodeWithTag("panel.done").performClick()
        rule.waitUntil(20_000) { count("clip.") == 4 }
    }

    @Test fun `MUS-2 adding a track puts music on the timeline`() {
        openProjectWithSamples()
        rule.onNodeWithTag("tool.Music").performClick()
        waitFor("music.use.sunrise")
        rule.onNodeWithTag("music.use.sunrise").performClick()
        rule.waitUntil(30_000) { count("audio.") == 1 }
        rule.onNodeWithTag("audio.0").performClick()
        waitFor("tool.Cut")
        shot("phone-07-music")
        for (t in listOf("tool.Cut", "tool.Duck", "tool.Delete")) rule.onNodeWithTag(t).assertIsDisplayed()
    }

    @Test fun `EXP-1 export screen shows options and the estimate`() {
        openProjectWithSamples()
        rule.onNodeWithTag("editor.export").performClick()
        waitFor("export.estimate")
        shot("phone-08-export")
        assertTrue(rule.onAllNodesWithTag("export.start").fetchSemanticsNodes().isNotEmpty())
    }

    @Test fun `DUR-1 Duration panel on a photo with quick pick`() {
        openPhotoTool("tool.Duration", "panel.Duration")
        rule.onNodeWithTag("duration.value").assertIsDisplayed()
        rule.onNodeWithTag("chip.5s").performClick()
        rule.waitForIdle()
        shot("phone-09-duration")
        rule.onNodeWithTag("panel.done").performClick()
        waitFor("editor.undo")
    }

    @Test fun `ANM-4 Animate panel Motion tab on a photo`() {
        openPhotoTool("tool.Animate", "panel.Animate")
        rule.onNodeWithTag("animate.tabs").assertIsDisplayed()
        rule.onNodeWithText("Motion").performClick()
        waitFor("motion.ZOOM_IN")
        rule.onNodeWithTag("motion.ZOOM_IN").performClick()
        rule.waitForIdle()
        shot("phone-10-animate-motion")
        rule.onNodeWithTag("panel.done").performClick()
    }

    @Test fun `ADJ-1 Adjust panel opens for a photo`() {
        openPhotoTool("tool.Adjust", "panel.Adjust")
        rule.onNodeWithTag("panel.Adjust").assertIsDisplayed()
        rule.onNodeWithTag("adjust.reset").performScrollTo().assertIsDisplayed()
        shot("phone-11-adjust")
        rule.onNodeWithTag("panel.done").performClick()
    }

    @Test fun `CRP-1 Crop panel opens for a photo`() {
        openPhotoTool("tool.Crop", "panel.Crop")
        rule.onNodeWithTag("crop.fit").assertIsDisplayed()
        rule.onNodeWithTag("chip.Rotate").performClick()
        rule.waitForIdle()
        shot("phone-12-crop")
        rule.onNodeWithTag("panel.done").performClick()
        waitFor("editor.undo")
    }

    @Test fun `CNV-1 Canvas panel via aspect button`() {
        openProjectWithSamples()
        rule.onNodeWithTag("editor.aspect").performClick()
        waitFor("panel.Canvas")
        rule.onNodeWithTag("ratio.1:1").performClick()
        rule.waitForIdle()
        shot("phone-13-canvas")
        rule.onNodeWithTag("panel.done").performClick()
        waitFor("editor.undo")
    }

    @Test fun `WMK-1 Watermark panel text kind`() {
        openProjectWithSamples()
        rule.onNodeWithTag("tool.Watermark").performClick()
        waitFor("panel.Watermark")
        rule.onNodeWithTag("chip.Text").performClick()
        waitFor("watermark.text")
        shot("phone-14-watermark")
        rule.onNodeWithTag("panel.done").performClick()
        waitFor("editor.undo")
    }

    @Test fun `TTL-1 closing slide is added as the last clip`() {
        openProjectWithSamples()
        rule.onNodeWithTag("tool.Outro").performClick()
        waitFor("panel.Closing Slide")
        rule.onNodeWithTag("titleStyle.ocean").performClick()
        shot("phone-15-outro")
        rule.onNodeWithTag("panel.done").performClick()
        rule.waitUntil(20_000) { count("clip.") == 4 }
    }

    @Test fun `PRJ-2 undo appears after edit and redo after undo`() {
        openProjectWithSamples()
        // Adding samples is already an edit (PRJ-2): undo is shown, redo is not.
        waitFor("editor.undo")
        assertEquals(0, rule.onAllNodesWithTag("editor.redo").fetchSemanticsNodes().size)
        rule.onNodeWithTag("clip.0").performClick()
        waitFor("tool.Duration")
        rule.onNodeWithTag("tool.Duration").performClick()
        waitFor("panel.Duration")
        rule.onNodeWithTag("chip.5s").performClick()
        rule.waitForIdle()
        rule.onNodeWithTag("panel.done").performClick()
        waitFor("editor.undo")
        rule.onNodeWithTag("editor.undo").assertIsDisplayed()
        assertEquals(0, rule.onAllNodesWithTag("editor.redo").fetchSemanticsNodes().size)
        rule.onNodeWithTag("editor.undo").performClick()
        waitFor("editor.redo")
        rule.onNodeWithTag("editor.redo").assertIsDisplayed()
        shot("phone-16-undo-redo")
    }
}

/** LAY-1…3: a wide (tablet landscape) window shows the sidebar with a tool grid. */
@Config(sdk = [35], qualifiers = "w1280dp-h800dp-land-xhdpi")
class TabletUiTest : CutlineUiTest() {
    @Test fun `LAY-2 wide layout with the sidebar`() {
        openProjectWithSamples()
        waitFor("editor.sidebar")
        assertEquals(0, rule.onAllNodesWithTag("toolbar").fetchSemanticsNodes().size)
        shot("tablet-01-editor")
        rule.onNodeWithTag("clip.1").performClick()
        waitFor("tool.Duration")
        rule.onNodeWithTag("tool.Adjust").performClick()
        waitFor("panel.Adjust")
        shot("tablet-02-adjust")
    }

    @Test fun `LAY-6 library grid on a wide window`() {
        launch()
        waitFor("projects.new")
        shot("tablet-00-library")
    }

    @Test fun `LAY-2 Music panel fills the sidebar`() {
        openProjectWithSamples()
        waitFor("editor.sidebar")
        rule.onNodeWithTag("tool.Music").performClick()
        waitFor("panel.Music")
        waitFor("music.use.sunrise")
        shot("tablet-03-music")
        rule.onNodeWithTag("panel.done").performClick()
        waitGone("panel.Music")
        rule.onNodeWithTag("editor.sidebar").assertIsDisplayed()
    }

    @Test fun `LAY-2 Text then Filters on a selected clip in the sidebar`() {
        openProjectWithSamples()
        waitFor("editor.sidebar")
        rule.onNodeWithTag("tool.Text").performClick()
        waitFor("panel.Text")
        waitFor("text.0")
        shot("tablet-04-text")
        rule.onNodeWithTag("panel.done").performClick()
        waitGone("panel.Text")
        rule.onNodeWithTag("clip.0").performClick()
        waitFor("tool.Filters")
        rule.onNodeWithTag("tool.Filters").performClick()
        waitFor("panel.Filters")
        rule.onNodeWithTag("filter.vivid").performClick()
        rule.waitForIdle()
        shot("tablet-05-filters")
        rule.onNodeWithTag("panel.done").performClick()
        waitFor("editor.undo")
    }

    @Test fun `LAY-6 library opens editor then export on a wide window`() {
        launch()
        waitFor("projects.new")
        openProjectWithSamples()
        waitFor("editor.sidebar")
        rule.onNodeWithTag("editor.export").performClick()
        waitFor("export.estimate")
        shot("tablet-06-export")
        assertTrue(rule.onAllNodesWithTag("export.start").fetchSemanticsNodes().isNotEmpty())
    }
}
