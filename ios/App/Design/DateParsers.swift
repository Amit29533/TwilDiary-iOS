import Foundation

/// Date parsers made once and kept: making a formatter is slow, and rows that made one on every
/// redraw (the calendar's days and headings, a JellySpace episode's air date, the Server page's
/// task times) paid for it again and again while scrolling.
@MainActor enum DateParsers {
    /// "2026-11-26": a calendar day (Gregorian, the phone's time zone).
    static let day: DateFormatter = {
        let parser = DateFormatter()
        parser.calendar = Calendar(identifier: .gregorian)
        parser.dateFormat = "yyyy-MM-dd"
        return parser
    }()
    /// "2024-10-10T18:30:00" read as UTC (Jellyfin's air dates, to the second).
    static let utcSeconds: DateFormatter = {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return parser
    }()
    /// "2026-11-26T04:00:01Z".
    static let internet = ISO8601DateFormatter()
    /// "2 minutes ago", "yesterday".
    static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}
