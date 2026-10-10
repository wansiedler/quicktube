import Foundation

/// One timestamp names both the file and the YouTube title.
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
}
