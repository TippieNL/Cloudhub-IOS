import Foundation

/// Sidecar subtitles, drawn by the app over the video.
///
/// AVPlayer cannot add a WebVTT file to a progressive MP4 it is already
/// playing, so the server's track (always WebVTT -- it converts SubRip on the
/// way out) is parsed here and the cue for the current time is shown on top.
public struct SubtitleCue: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

public enum WebVTT {
    /// Cues in time order. Anything that is not a cue -- the header, NOTE and
    /// STYLE blocks, a malformed timing line -- is skipped rather than failing
    /// the track.
    public static func parse(_ source: String) -> [SubtitleCue] {
        let normalised = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [SubtitleCue] = []
        for block in normalised.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timingIndex].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = seconds(parts[0]),
                  let end = seconds(parts[1].split(separator: " ", omittingEmptySubsequences: true).first.map(String.init) ?? "")
            else { continue }
            let text = lines[(timingIndex + 1)...]
                .map(stripTags)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty && end > start { cues.append(SubtitleCue(start: start, end: end, text: text)) }
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// "01:02:03.456", "02:03.456" or "02:03,456" (SubRip's comma).
    public static func seconds(_ raw: String) -> Double? {
        let text = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let fields = text.split(separator: ":").map(String.init)
        guard fields.count == 2 || fields.count == 3 else { return nil }
        var total = 0.0
        for field in fields {
            guard let value = Double(field) else { return nil }
            total = total * 60 + value
        }
        return total
    }

    /// The cue showing at `time`, by binary search -- this runs on every tick.
    public static func cue(at time: Double, in cues: [SubtitleCue]) -> SubtitleCue? {
        var low = 0
        var high = cues.count - 1
        var candidate: Int?
        while low <= high {
            let mid = (low + high) / 2
            if cues[mid].start <= time {
                candidate = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        guard let index = candidate else { return nil }
        // Overlapping cues: the latest one that has started and not ended.
        var k = index
        while k >= 0 && k > index - 8 {
            if cues[k].start <= time && time < cues[k].end { return cues[k] }
            k -= 1
        }
        return nil
    }

    /// `<i>`, `<b>`, `<c.yellow>` and voice tags carry nothing worth keeping here.
    private static func stripTags(_ line: String) -> String {
        line.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }
}
