package com.mujassir.cutline.engine

import android.content.Context
import android.graphics.BitmapFactory
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import androidx.exifinterface.media.ExifInterface
import com.mujassir.cutline.core.MediaItem
import com.mujassir.cutline.core.MediaKind
import com.mujassir.cutline.core.MediaTime
import com.mujassir.cutline.core.ProjectStore
import com.mujassir.cutline.core.Size
import java.io.File
import java.util.UUID

/**
 * Copies picked media into the project and reads what the editor needs (IMPLEMENTATION §12):
 * upright size, rotation as clockwise quarter turns, frame rate, duration and whether there's sound.
 */
class MediaImporter(private val context: Context, private val store: ProjectStore) {

    /** Imports one picked item. Returns null when it can't be read (the copy is removed). */
    fun import(uri: Uri, projectID: UUID): MediaItem? {
        val resolver = context.contentResolver
        val mime = resolver.getType(uri) ?: ""
        val displayName = displayName(uri)
        val ext = MimeTypeMap.getSingleton().getExtensionFromMimeType(mime)
            ?: displayName?.substringAfterLast('.', "")?.takeIf { it.isNotEmpty() }
        val fileName = resolver.openInputStream(uri)?.use { store.importStream(it, ext, projectID) } ?: return null
        val file = store.mediaFile(fileName, projectID)
        val name = displayName?.substringBeforeLast('.') ?: "Media"
        val item = runCatching { probe(file, fileName, name, mime) }.getOrNull()
        if (item == null) file.delete()
        return item
    }

    /** Imports a file that's already on disk (samples, recent audio). */
    fun importFile(source: File, projectID: UUID, displayName: String = source.nameWithoutExtension): MediaItem? {
        val fileName = source.inputStream().use { store.importStream(it, source.extension, projectID) }
        val file = store.mediaFile(fileName, projectID)
        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(source.extension.lowercase()) ?: ""
        val item = runCatching { probe(file, fileName, displayName, mime) }.getOrNull()
        if (item == null) file.delete()
        return item
    }

    private fun displayName(uri: Uri): String? = runCatching {
        context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) c.getString(0) else null
        }
    }.getOrNull() ?: uri.lastPathSegment

    companion object {
        fun probe(file: File, fileName: String, displayName: String, mime: String): MediaItem? {
            if (mime.startsWith("image/") || isImageExtension(file.extension)) return probeImage(file, fileName, displayName)
            // WAV: read the header ourselves. MediaMetadataRetriever often fails on Robolectric and some devices.
            if (isWav(file.extension, mime)) return probeWav(file, fileName, displayName) ?: runCatching { probeAV(file, fileName, displayName) }.getOrNull()
            return probeAV(file, fileName, displayName)
        }

        private fun isImageExtension(ext: String) = ext.lowercase() in setOf("jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "bmp")

        private fun isWav(ext: String, mime: String) =
            ext.equals("wav", ignoreCase = true) || mime.equals("audio/wav", ignoreCase = true) || mime.equals("audio/x-wav", ignoreCase = true)

        private fun probeImage(file: File, fileName: String, displayName: String): MediaItem? {
            val opts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(file.absolutePath, opts)
            if (opts.outWidth <= 0 || opts.outHeight <= 0) return null
            val turns = runCatching { exifQuarterTurns(ExifInterface(file.absolutePath)) }.getOrDefault(0)
            val w = opts.outWidth.toDouble(); val h = opts.outHeight.toDouble()
            // Photos are decoded upright, so naturalSize is upright and no source turns are needed.
            val size = if (turns % 2 == 1) Size(h, w) else Size(w, h)
            return MediaItem(kind = MediaKind.PHOTO, fileName = fileName, naturalSize = size, duration = MediaTime.ZERO,
                hasAudio = false, displayName = displayName)
        }

        fun exifQuarterTurns(exif: ExifInterface): Int = when (exif.getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)) {
            ExifInterface.ORIENTATION_ROTATE_90, ExifInterface.ORIENTATION_TRANSPOSE -> 1
            ExifInterface.ORIENTATION_ROTATE_180, ExifInterface.ORIENTATION_FLIP_VERTICAL -> 2
            ExifInterface.ORIENTATION_ROTATE_270, ExifInterface.ORIENTATION_TRANSVERSE -> 3
            else -> 0
        }

        /** PCM WAV from a standard 44-byte header (sample tracks for UI tests / demos). */
        fun probeWav(file: File, fileName: String, displayName: String): MediaItem? = runCatching {
            file.inputStream().use { input ->
                val hdr = ByteArray(44)
                if (input.read(hdr) < 44) return null
                if (String(hdr, 0, 4) != "RIFF" || String(hdr, 8, 4) != "WAVE") return null
                fun le16(i: Int) = (hdr[i].toInt() and 0xff) or ((hdr[i + 1].toInt() and 0xff) shl 8)
                fun le32(i: Int) = le16(i) or (le16(i + 2) shl 16)
                val channels = le16(22)
                val rate = le32(24)
                val bits = le16(34)
                val dataBytes = le32(40)
                val bytesPerFrame = channels * (bits / 8)
                if (rate <= 0 || bytesPerFrame <= 0 || dataBytes <= 0) return null
                val duration = MediaTime.seconds(dataBytes.toDouble() / (rate * bytesPerFrame))
                if (duration <= MediaTime.ZERO) return null
                MediaItem(kind = MediaKind.AUDIO, fileName = fileName, naturalSize = Size.ZERO, duration = duration,
                    hasAudio = true, displayName = displayName)
            }
        }.getOrNull()

        private fun probeAV(file: File, fileName: String, displayName: String): MediaItem? {
            val r = MediaMetadataRetriever()
            try {
                r.setDataSource(file.absolutePath)
                val hasVideo = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_VIDEO) == "yes"
                val hasAudio = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO) == "yes"
                val ms = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
                val duration = MediaTime(ms * MediaTime.TIMESCALE / 1000)
                if (!hasVideo) {
                    if (!hasAudio || ms <= 0) return null
                    // A container with no video track is audio.
                    return MediaItem(kind = MediaKind.AUDIO, fileName = fileName, naturalSize = Size.ZERO, duration = duration,
                        hasAudio = true, displayName = displayName)
                }
                val w = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toDoubleOrNull() ?: 0.0
                val h = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toDoubleOrNull() ?: 0.0
                val rotation = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
                val turns = ((rotation / 90) % 4 + 4) % 4
                val size = if (turns % 2 == 1) Size(h, w) else Size(w, h)
                return MediaItem(kind = MediaKind.VIDEO, fileName = fileName, naturalSize = size, duration = duration,
                    hasAudio = hasAudio, frameRate = frameRate(file), displayName = displayName, sourceQuarterTurns = turns)
            } finally {
                r.release()
            }
        }

        /** Frame rate from the video track (30 if unknown). */
        private fun frameRate(file: File): Double = runCatching {
            val ex = MediaExtractor()
            try {
                ex.setDataSource(file.absolutePath)
                (0 until ex.trackCount).map { ex.getTrackFormat(it) }
                    .firstOrNull { it.getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true }
                    ?.takeIf { it.containsKey(MediaFormat.KEY_FRAME_RATE) }
                    ?.let { f -> runCatching { f.getInteger(MediaFormat.KEY_FRAME_RATE).toDouble() }.getOrElse { f.getFloat(MediaFormat.KEY_FRAME_RATE).toDouble() } }
            } finally {
                ex.release()
            }
        }.getOrNull()?.takeIf { it > 0 } ?: 30.0
    }
}
