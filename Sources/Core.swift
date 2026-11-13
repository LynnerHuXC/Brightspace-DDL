import Foundation

enum CalendarImport {
    case snapshot([CalendarEvent])
    case subscription(String)

    static func read(_ data: Data, fileExtension: String) throws -> CalendarImport {
        if fileExtension.lowercased() == "ics" {
            guard let text = String(data: data, encoding: .utf8) else { throw ICS.Failure.invalid }
            return .snapshot(try ICS.parse(text))
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: String],
              let value = object["feed_url"] else { throw ICS.Failure.invalid }
        return .subscription(value)
    }
}

struct CalendarEvent: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var course: String
    var date: Date
    var allDay: Bool = false
    var url: URL? = nil
    var sequence: Int = 0
    var source: String? = nil
    var submitted: Bool? = nil
    var observedAt: Date? = nil
    var sourceName: String { source == "keenly" ? "Keenly" : source == "gradescope" ? "Gradescope" : source == "webassign" ? "Cengage / WebAssign" : "Brightspace" }
    var dateLabel: String {
        let label = NYTime.display(date, allDay: allDay)
        return source == "keenly" && allDay ? label.replacingOccurrences(of: "全天", with: "截止时间未注明") : label
    }
    var hasExactDeadline: Bool { !(source == "keenly" && allDay) }
    var isDue: Bool { source != nil || title.lowercased().hasSuffix(" - due") }
    var deadline: Date {
        allDay ? NYTime.calendar.date(byAdding: .day, value: 1, to: date)!.addingTimeInterval(-1) : date
    }
}

enum NYTime {
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }
    static func dayKey(_ date: Date) -> String {
        let d = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", d.year!, d.month!, d.day!)
    }
    static func shouldSendDaily(now: Date, lastDay: String?) -> Bool {
        calendar.component(.hour, from: now) >= 17 && lastDay != dayKey(now)
    }
    static func display(_ date: Date, allDay: Bool = false) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = calendar.timeZone
        f.dateFormat = allDay ? "M月d日（全天）" : "M月d日 EEE HH:mm"
        return f.string(from: date)
    }
}

enum ICS {
    enum Failure: LocalizedError {
        case invalid, unsupported, date
        var errorDescription: String? {
            switch self {
            case .invalid: return "订阅返回了无效日历，已保留上次数据。"
            case .unsupported: return "日历含尚不支持的重复事件，请在 Brightspace 核实；已保留上次数据。"
            case .date: return "日历日期或时区无法识别，已保留上次数据。"
            }
        }
    }
    static func parse(_ text: String) throws -> [CalendarEvent] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}")))
        guard normalized.hasPrefix("BEGIN:VCALENDAR\n"), normalized.hasSuffix("END:VCALENDAR") else { throw Failure.invalid }
        var lines: [String] = []
        for line in normalized.components(separatedBy: "\n") {
            if (line.hasPrefix(" ") || line.hasPrefix("\t")), !lines.isEmpty { lines[lines.count - 1] += line.dropFirst() }
            else { lines.append(line) }
        }
        var fields: [String: (String, String)]? = nil
        var nested = 0
        var events: [String: CalendarEvent] = [:]
        for line in lines {
            if line == "BEGIN:VEVENT" {
                guard fields == nil else { throw Failure.invalid }
                fields = [:]; nested = 0; continue
            }
            guard fields != nil else { continue }
            if line == "END:VEVENT" {
                guard nested == 0, let uid = fields?["UID"]?.1, !uid.isEmpty,
                      let title = fields?["SUMMARY"]?.1, let start = fields?["DTSTART"] else { throw Failure.invalid }
                if fields?["RRULE"] != nil || fields?["RDATE"] != nil || fields?["RECURRENCE-ID"] != nil { throw Failure.unsupported }
                let (date, allDay) = try parseDate(start.1, parameters: start.0)
                let description = unescape(fields?["DESCRIPTION"]?.1 ?? "")
                let source = fields?["URL"]?.1 ?? description.components(separatedBy: .whitespacesAndNewlines).first(where: { $0.hasPrefix("https://brightspace.nyu.edu/") })
                let url = source.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" && $0.host == "brightspace.nyu.edu" ? $0 : nil }
                if fields?["STATUS"]?.1 != "CANCELLED" {
                    let event = CalendarEvent(id: uid, title: unescape(title), course: unescape(fields?["LOCATION"]?.1 ?? "课程未注明"), date: date, allDay: allDay, url: url, sequence: Int(fields?["SEQUENCE"]?.1 ?? "0") ?? 0)
                    if event.sequence >= (events[uid]?.sequence ?? -1) { events[uid] = event }
                }
                fields = nil; continue
            }
            if line.hasPrefix("BEGIN:") { nested += 1; continue }
            if line.hasPrefix("END:") { nested -= 1; continue }
            guard nested == 0, let colon = line.firstIndex(of: ":") else { continue }
            let head = String(line[..<colon])
            let key = String(head.split(separator: ";")[0]).uppercased()
            fields?[key] = (head, String(line[line.index(after: colon)...]))
        }
        guard fields == nil else { throw Failure.invalid }
        return events.values.sorted { $0.deadline < $1.deadline }
    }
    private static func parseDate(_ value: String, parameters: String) throws -> (Date, Bool) {
        let allDay = parameters.uppercased().components(separatedBy: ";").contains("VALUE=DATE")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.isLenient = false
        formatter.timeZone = NYTime.calendar.timeZone
        if let tz = parameters.components(separatedBy: ";").first(where: { $0.uppercased().hasPrefix("TZID=") }) {
            guard let zone = TimeZone(identifier: String(tz.dropFirst(5)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))) else { throw Failure.date }
            formatter.timeZone = zone
        }
        if value.hasSuffix("Z") { formatter.timeZone = TimeZone(secondsFromGMT: 0) }
        formatter.dateFormat = allDay ? "yyyyMMdd" : (value.hasSuffix("Z") ? "yyyyMMdd'T'HHmmss'Z'" : "yyyyMMdd'T'HHmmss")
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else { throw Failure.date }
        return (date, allDay)
    }
    private static func unescape(_ text: String) -> String {
        var result = "", escaped = false
        for character in text {
            if escaped {
                result.append(character == "n" || character == "N" ? "\n" : character)
                escaped = false
            } else if character == "\\" { escaped = true }
            else { result.append(character) }
        }
        if escaped { result.append("\\") }
        return result
    }
}

struct EventChange: Equatable {
    let current: CalendarEvent
    let previousDate: Date?
}

func changes(from old: [CalendarEvent], to new: [CalendarEvent], now: Date) -> [EventChange] {
    let previous = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
    return new.filter { $0.isDue && $0.submitted != true }.compactMap { event in
        if let before = previous[event.id] {
            return before.date != event.date || before.allDay != event.allDay ? EventChange(current: event, previousDate: before.date) : nil
        }
        return event.deadline >= now ? EventChange(current: event, previousDate: nil) : nil
    }
}

func upcoming(_ events: [CalendarEvent], now: Date) -> [CalendarEvent] {
    let end = NYTime.calendar.date(byAdding: .day, value: 7, to: now)!
    return events.filter { $0.isDue && $0.submitted != true && $0.deadline >= now && $0.date <= end }.sorted { $0.deadline < $1.deadline }
}
