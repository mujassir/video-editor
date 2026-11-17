package com.mujassir.cutline.core

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlin.math.abs
import kotlin.math.floor

/** Rounds half away from zero, like Swift's `.rounded()` (IMPLEMENTATION §2). */
fun roundHalfAway(x: Double): Double = if (x >= 0) floor(x + 0.5) else -floor(-x + 0.5)

/**
 * Frame-accurate time: integer ticks at 60 000 per second (IMPLEMENTATION §2).
 * Encoded in JSON as a bare integer.
 */
@Serializable(with = MediaTimeSerializer::class)
data class MediaTime(val ticks: Long) : Comparable<MediaTime> {
    companion object {
        const val TIMESCALE: Long = 60_000
        val ZERO = MediaTime(0)
        fun seconds(seconds: Double) = MediaTime(roundHalfAway(seconds * TIMESCALE).toLong())
        fun seconds(seconds: Int) = MediaTime(seconds * TIMESCALE)
        fun min(a: MediaTime, b: MediaTime) = if (a <= b) a else b
        fun max(a: MediaTime, b: MediaTime) = if (a >= b) a else b
    }

    val seconds: Double get() = ticks.toDouble() / TIMESCALE
    val millis: Long get() = ticks * 1000 / TIMESCALE
    val micros: Long get() = ticks * 1_000_000 / TIMESCALE

    override fun compareTo(other: MediaTime) = ticks.compareTo(other.ticks)
    operator fun plus(o: MediaTime) = MediaTime(ticks + o.ticks)
    operator fun minus(o: MediaTime) = MediaTime(ticks - o.ticks)
    operator fun unaryMinus() = MediaTime(-ticks)

    /** Scales a duration by a playback rate (a 4 s source at 2× lasts 2 s). */
    fun dividedBy(rate: Double) = MediaTime(roundHalfAway(ticks / rate).toLong())
    fun multipliedBy(factor: Double) = MediaTime(roundHalfAway(ticks * factor).toLong())
    fun half() = MediaTime(ticks / 2)

    fun clamped(lower: MediaTime, upper: MediaTime): MediaTime = max(lower, min(this, upper))

    /** Rounds to the nearest frame boundary for the given frame rate. */
    fun snappedToFrame(fps: Int): MediaTime {
        val perFrame = TIMESCALE / fps.coerceAtLeast(1)
        val frames = roundHalfAway(ticks.toDouble() / perFrame).toLong()
        return MediaTime(frames * perFrame)
    }

    /** "m:ss.f" label for the UI. */
    val timecode: String
        get() {
            val total = seconds.coerceAtLeast(0.0)
            val minutes = total.toInt() / 60
            val secs = total - minutes * 60
            return "%d:%04.1f".format(java.util.Locale.US, minutes, secs)
        }

    /** "m:ss" label (rounded to the second). */
    val clock: String
        get() {
            val t = roundHalfAway(seconds.coerceAtLeast(0.0)).toInt()
            return "%d:%02d".format(java.util.Locale.US, t / 60, t % 60)
        }

    override fun toString() = "%.3fs".format(java.util.Locale.US, seconds)
}

fun absTicks(t: MediaTime) = abs(t.ticks)

object MediaTimeSerializer : KSerializer<MediaTime> {
    override val descriptor = PrimitiveSerialDescriptor("MediaTime", PrimitiveKind.LONG)
    override fun serialize(encoder: Encoder, value: MediaTime) = encoder.encodeLong(value.ticks)
    override fun deserialize(decoder: Decoder) = MediaTime(decoder.decodeLong())
}

/** Half-open range [start, start + duration). */
@Serializable
data class MediaTimeRange(val start: MediaTime, val duration: MediaTime) {
    companion object {
        fun of(start: MediaTime, end: MediaTime) = MediaTimeRange(start, end - start)
        val EMPTY get() = MediaTimeRange(MediaTime.ZERO, MediaTime.ZERO)
    }

    val end: MediaTime get() = start + duration
    val isEmpty: Boolean get() = duration.ticks <= 0

    operator fun contains(time: MediaTime) = time >= start && time < end

    fun intersection(other: MediaTimeRange): MediaTimeRange? {
        val s = MediaTime.max(start, other.start)
        val e = MediaTime.min(end, other.end)
        return if (e > s) of(s, e) else null
    }

    override fun toString() = "[$start – $end)"
}
