import CoreMedia

/// Frame-accurate time value used throughout the project model.
///
/// Stored as integer ticks at a fixed timescale (60 000 per second), which is
/// exactly divisible by every common frame rate (24, 25, 30, 48, 50, 60, 120)
/// and avoids floating-point drift when clips are split and trimmed repeatedly.
public struct MediaTime: Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public static let timescale: Int64 = 60_000

    public var ticks: Int64

    public init(ticks: Int64) { self.ticks = ticks }

    public init(seconds: Double) {
        self.ticks = Int64((seconds * Double(Self.timescale)).rounded())
    }

    public init(_ time: CMTime) {
        guard time.isNumeric else { self.ticks = 0; return }
        let converted = CMTimeConvertScale(time, timescale: Int32(Self.timescale), method: .roundHalfAwayFromZero)
        self.ticks = converted.value
    }

    public static let zero = MediaTime(ticks: 0)

    public var seconds: Double { Double(ticks) / Double(Self.timescale) }
    public var cmTime: CMTime { CMTime(value: ticks, timescale: CMTimeScale(Self.timescale)) }

    public static func < (lhs: MediaTime, rhs: MediaTime) -> Bool { lhs.ticks < rhs.ticks }
    public static func + (lhs: MediaTime, rhs: MediaTime) -> MediaTime { MediaTime(ticks: lhs.ticks + rhs.ticks) }
    public static func - (lhs: MediaTime, rhs: MediaTime) -> MediaTime { MediaTime(ticks: lhs.ticks - rhs.ticks) }
    public static func += (lhs: inout MediaTime, rhs: MediaTime) { lhs.ticks += rhs.ticks }
    public static func -= (lhs: inout MediaTime, rhs: MediaTime) { lhs.ticks -= rhs.ticks }

    /// Scales a duration by a playback rate (e.g. a 4 s source at 2× lasts 2 s).
    public func divided(by rate: Double) -> MediaTime {
        MediaTime(ticks: Int64((Double(ticks) / rate).rounded()))
    }

    public func multiplied(by factor: Double) -> MediaTime {
        MediaTime(ticks: Int64((Double(ticks) * factor).rounded()))
    }

    public func clamped(to range: ClosedRange<MediaTime>) -> MediaTime {
        min(max(self, range.lowerBound), range.upperBound)
    }

    /// Rounds to the nearest frame boundary for the given frame rate.
    public func snappedToFrame(fps: Int) -> MediaTime {
        let ticksPerFrame = Self.timescale / Int64(max(fps, 1))
        let frames = (Double(ticks) / Double(ticksPerFrame)).rounded()
        return MediaTime(ticks: Int64(frames) * ticksPerFrame)
    }

    public var description: String { String(format: "%.3fs", seconds) }

    /// "m:ss.f" style label for UI.
    public var timecode: String {
        let total = max(seconds, 0)
        let minutes = Int(total) / 60
        let secs = total - Double(minutes * 60)
        return String(format: "%d:%04.1f", minutes, secs)
    }

    // Codable as a bare integer to keep project files compact.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        ticks = try container.decode(Int64.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(ticks)
    }
}

/// Half-open time range [start, start + duration).
public struct MediaTimeRange: Codable, Hashable, Sendable, CustomStringConvertible {
    public var start: MediaTime
    public var duration: MediaTime

    public init(start: MediaTime, duration: MediaTime) {
        self.start = start
        self.duration = duration
    }

    public init(start: MediaTime, end: MediaTime) {
        self.start = start
        self.duration = end - start
    }

    public var end: MediaTime { start + duration }
    public var isEmpty: Bool { duration.ticks <= 0 }
    public var cmTimeRange: CMTimeRange { CMTimeRange(start: start.cmTime, duration: duration.cmTime) }

    public func contains(_ time: MediaTime) -> Bool { time >= start && time < end }

    public func intersection(_ other: MediaTimeRange) -> MediaTimeRange? {
        let s = max(start, other.start)
        let e = min(end, other.end)
        return e > s ? MediaTimeRange(start: s, end: e) : nil
    }

    public var description: String { "[\(start) – \(end))" }
}
