import Foundation

/// What a title template can refer to.
public struct TitleContext: Sendable {
    public var date: Date
    /// Frontmost application at the start of the recording.
    public var app: String?
    /// Name of the recorded screen.
    public var display: String?
    public var timeZone: TimeZone

    public init(
        date: Date = Date(), app: String? = nil, display: String? = nil,
        timeZone: TimeZone = .current
    ) {
        self.date = date
        self.app = app
        self.display = display
        self.timeZone = timeZone
    }
}

/// One timestamp names the recording; the title template names the final file and the upload.
public enum RecordingNaming {
    public static func title(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: date)
    }

    public static func fileName(for date: Date, timeZone: TimeZone = .current) -> String {
        title(for: date, timeZone: timeZone) + ".mp4"
    }

    /// Fills `{date}`, `{app}` and `{display}`; missing values vanish, spaces collapse, and an empty
    /// result falls back to the date. `/` and `:` become `-` so the title is also a file name.
    public static func render(template: String, context: TitleContext) -> String {
        let date = title(for: context.date, timeZone: context.timeZone)
        let filled =
            template
            .replacingOccurrences(of: "{date}", with: date)
            .replacingOccurrences(of: "{app}", with: context.app ?? "")
            .replacingOccurrences(of: "{display}", with: context.display ?? "")
        let collapsed = filled.split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        let result = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        return (result.isEmpty ? date : result)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }

    /// "Built-in Retina Display · 1920×1080 · 30 fps"; the display is left out when unknown.
    public static func metadataLine(display: String?, info: VideoInfo) -> String {
        var parts: [String] = []
        if let display, !display.isEmpty { parts.append(display) }
        parts.append("\(info.width)×\(info.height)")
        if let fps = info.fps { parts.append("\(Int(fps.rounded())) fps") }
        return parts.joined(separator: " · ")
    }

    /// "Compressing · 6016×3384 60 fps 120 MB → 6016×3384 60 fps ~48 MB"; the after size is the target.
    public static func compressionLine(
        from info: VideoInfo, sizeBytes: Int, to plan: TranscodePlan, targetBytes: Int
    ) -> String {
        func format(width: Int, height: Int, fps: Double?, bytes: Int, approximate: Bool) -> String {
            var text = "\(width)×\(height)"
            if let fps { text += " \(Int(fps.rounded())) fps" }
            let megabytes = Int((Double(bytes) / 1_048_576).rounded())
            return text + " \(approximate ? "~" : "")\(megabytes) MB"
        }
        let before = format(
            width: info.width, height: info.height, fps: info.fps, bytes: sizeBytes, approximate: false)
        let after = format(
            width: plan.width, height: plan.height, fps: info.fps, bytes: targetBytes, approximate: true)
        return "Compressing · \(before) → \(after)"
    }
}
