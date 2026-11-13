import Foundation
import CryptoKit

struct ExternalPayload: Decodable {
    struct Item: Decodable {
        var id: String
        var title: String
        var due: String
        var submitted: Bool?
        var url: String
        var dateOnly: Bool? = nil
        var course: String? = nil
    }
    var version: Int
    var source: String
    var courseKey: String
    var course: String
    var warning: String?
    var events: [Item]
    var completedIDs: [String]? = nil

    func snapshot(now: Date = Date()) throws -> ExternalSnapshot {
        func validText(_ value: String, max: Int) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= max && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        }
        guard version == 1, ["gradescope", "webassign", "keenly"].contains(source),
              validText(courseKey, max: 500), validText(course, max: 500),
              events.count <= 2000, (warning?.count ?? 0) <= 1000 else { throw ICS.Failure.invalid }
        let idPattern = source == "keenly" ? "^[A-Za-z0-9_-]{1,100}$" : "^[0-9]{1,24}$"
        guard (completedIDs?.count ?? 0) <= 2000,
              (completedIDs ?? []).allSatisfy({ $0.range(of: idPattern, options: .regularExpression) != nil }),
              source != "keenly" || courseKey == "tasks" else { throw ICS.Failure.invalid }
        let key = source + "-" + SHA256.hash(data: Data(courseKey.utf8)).map { String(format: "%02x", $0) }.joined()
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var ids = Set<String>()
        let parsed = try events.map { item -> CalendarEvent in
            let dateOnly = source == "keenly" && item.dateOnly == true
            var parsedDate = format.date(from: item.due)
            if dateOnly {
                let day = DateFormatter()
                day.locale = Locale(identifier: "en_US_POSIX")
                day.calendar = NYTime.calendar; day.timeZone = NYTime.calendar.timeZone
                day.dateFormat = "yyyy-MM-dd"; day.isLenient = false
                parsedDate = day.date(from: item.due)
                if let date = parsedDate, day.string(from: date) != item.due { parsedDate = nil }
            }
            guard item.id.range(of: idPattern, options: .regularExpression) != nil,
                  ids.insert(item.id).inserted, validText(item.title, max: 1000),
                  let date = parsedDate, date.timeIntervalSince1970 >= 946684800,
                  date.timeIntervalSince1970 < 4102444800 else { throw ICS.Failure.invalid }
            let expected: String
            if source == "gradescope" {
                guard courseKey.range(of: "^[0-9]{1,24}$", options: .regularExpression) != nil else { throw ICS.Failure.invalid }
                expected = "https://www.gradescope.com/courses/\(courseKey)/assignments/\(item.id)"
            } else if source == "keenly" { expected = "https://keenly.study/tasks/\(item.id)"
            } else { expected = "https://www.webassign.net/web/Student/Assignment-Responses/last?dep=\(item.id)" }
            guard item.url == expected else { throw ICS.Failure.invalid }
            let itemCourse = source == "keenly" ? (item.course ?? course) : course
            guard validText(itemCourse, max: 500) else { throw ICS.Failure.invalid }
            return CalendarEvent(id: "\(key):\(item.id)", title: item.title, course: itemCourse, date: date, allDay: dateOnly,
                url: URL(string: expected), source: source, submitted: source != "webassign" ? item.submitted : nil, observedAt: now)
        }
        return ExternalSnapshot(id: key, source: source, course: course, fetchedAt: now, warning: warning, events: parsed, completedIDs: source == "keenly" ? completedIDs?.map { "\(key):\($0)" } : nil)
    }
}

struct ExternalSnapshot: Codable, Identifiable, Equatable {
    var id: String
    var source: String
    var course: String
    var fetchedAt: Date
    var warning: String?
    var events: [CalendarEvent]
    var completedIDs: [String]? = nil

    func merging(previous: ExternalSnapshot?) -> ExternalSnapshot {
        // A partial list or a disappearance cannot establish cancellation/completion.
        var result = self
        let currentIDs = Set(events.map(\.id))
        result.events += (previous?.events ?? []).filter { !currentIDs.contains($0.id) }
        let completed = Set(completedIDs ?? [])
        result.events = result.events.map { event in
            var updated = event
            if completed.contains(event.id) { updated.submitted = true; updated.observedAt = fetchedAt }
            return updated
        }
        result.events.sort { $0.deadline < $1.deadline }
        return result
    }
    var displayName: String { source == "keenly" ? "Keenly" : source == "gradescope" ? "Gradescope" : "Cengage / WebAssign" }
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BrightspaceDDL/external", isDirectory: true)
    }
}
