import Foundation
import AppKit

var failures = 0
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    checks += 1
    if !condition() { failures += 1; print("FAIL: \(name)") }
}
func instant(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
func feed(_ body: String) -> String { "BEGIN:VCALENDAR\nVERSION:2.0\n\(body)\nEND:VCALENDAR" }
func item(_ uid: String = "one", _ date: String = "20260922T035900Z", extra: String = "") -> String {
    "BEGIN:VEVENT\nUID:\(uid)\nSUMMARY:Draft - Due\nLOCATION:Engineering\nDTSTART:\(date)\n\(extra)\nEND:VEVENT"
}
let now = instant("2026-09-21T20:00:00Z")
do {
    let imported = try CalendarImport.read(Data(feed(item()).utf8), fileExtension: "ics")
    if case .snapshot(let events) = imported { check(events.count == 1, "imports downloaded ICS snapshot") }
    else { check(false, "imports downloaded ICS snapshot") }
} catch { check(false, "imports downloaded ICS snapshot") }
MainActor.assumeIsolated {
    let editMenu = makeMainMenu().items.first(where: { $0.title == "编辑" })?.submenu
    let paste = editMenu?.items.first(where: { $0.keyEquivalent == "v" })
    check(paste?.action == #selector(NSText.paste(_:)) && paste?.keyEquivalentModifierMask == .command, "standard Command V routes paste through responder chain")
}
let parsed = try ICS.parse(feed(item(extra: "DESCRIPTION:See\\nhttps://brightspace.nyu.edu/d2l/test")))
check(parsed.count == 1, "reads event")
if let event = parsed.first {
    check(event.date == instant("2026-09-22T03:59:00Z"), "UTC time preserved")
    check(event.course == "Engineering" && event.isDue, "course and due classification")
    check(event.url?.host == "brightspace.nyu.edu", "source URL from description")
}
let folded = try ICS.parse(feed(item().replacingOccurrences(of: "SUMMARY:Draft - Due", with: "SUMMARY:A long\\,\n folded title - Due")))
check(folded.first?.title == "A long,folded title - Due", "unfold and unescape")
let zoned = try ICS.parse(feed(item().replacingOccurrences(of: "DTSTART:20260922T035900Z", with: "DTSTART;TZID=America/New_York:20261124T123000")))
check(zoned.first?.date == instant("2026-11-24T17:30:00Z"), "winter New York UTC offset")
do {
    let explicit = try ICS.parse(feed(item().replacingOccurrences(of: "DTSTART:", with: "DTSTART;VALUE=DATE-TIME:")))
    check(explicit.first?.allDay == false, "explicit DATE-TIME is not all day")
} catch { check(false, "explicit DATE-TIME is not all day") }
let allDay = try ICS.parse(feed(item().replacingOccurrences(of: "DTSTART:20260922T035900Z", with: "DTSTART;VALUE=DATE:20260921")))
check(allDay.first?.allDay == true && upcoming(allDay, now: now).count == 1, "all day today remains visible")
let dupes = try ICS.parse(feed(item(extra: "SEQUENCE:1") + "\n" + item("one", "20260923T035900Z", extra: "SEQUENCE:2")))
check(dupes.count == 1 && dupes.first?.sequence == 2, "duplicate UID uses newest sequence")
for bad in ["<html>Login</html>", feed(item("one", "nonsense")), feed(item(extra: "RRULE:FREQ=DAILY")), "BEGIN:VCALENDAR\n" + item()] {
    do { _ = try ICS.parse(bad); check(false, "reject malformed or unsupported feed") }
    catch { check(true, "reject malformed or unsupported feed") }
}
let empty = try ICS.parse(feed(""))
check(empty.isEmpty, "valid empty calendar allowed")
check(!NYTime.shouldSendDaily(now: now, lastDay: nil), "no daily before 17")
let five = instant("2026-09-21T21:00:00Z")
check(NYTime.shouldSendDaily(now: five, lastDay: nil), "daily at 17 New York")
check(!NYTime.shouldSendDaily(now: five, lastDay: NYTime.dayKey(five)), "no duplicate daily")
check(NYTime.shouldSendDaily(now: instant("2026-11-24T22:00:00Z"), lastDay: "2026-11-23"), "daily winter offset")
let changed = changes(from: parsed, to: dupes, now: now)
check(changed.count == 1 && changed.first?.previousDate == parsed.first?.date, "detect deadline change")
check(changes(from: parsed, to: [], now: now).isEmpty, "disappearance not called cancellation")
check(changes(from: parsed, to: parsed, now: now).isEmpty, "unchanged produces no alert")
let advanced = try ICS.parse(feed(item("one", "20260921T190000Z")))
check(changes(from: parsed, to: advanced, now: now).count == 1, "moving a known deadline into past still alerts")
if let path = CommandLine.arguments.dropFirst().first {
    let real = try ICS.parse(String(contentsOfFile: path, encoding: .utf8))
    print("Live fixture: \(real.count) events; \(upcoming(real, now: now).count) upcoming deadlines")
    check(real.contains { $0.title.contains("SLDP Application Draft") && $0.date == instant("2026-09-22T03:59:00Z") }, "real personal deadline")
}
// External events must use explicit due/status metadata; legacy cache remains decodable.
var externalObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(parsed[0])) as! [String: Any]
externalObject["source"] = "gradescope"
externalObject["submitted"] = true
let submitted = try JSONDecoder().decode(CalendarEvent.self, from: JSONSerialization.data(withJSONObject: externalObject))
check(upcoming([submitted], now: now).isEmpty, "submitted Gradescope assignment excluded from reminders")
externalObject["submitted"] = false
externalObject["title"] = "Homework 1"
let external = try JSONDecoder().decode(CalendarEvent.self, from: JSONSerialization.data(withJSONObject: externalObject))
check(upcoming([external], now: now).count == 1, "external explicit due without Brightspace title suffix")
let payload = ExternalPayload(version: 1, source: "gradescope", courseKey: "123", course: "Course",
    warning: nil, events: [.init(id: "456", title: "PS 1", due: "2026-10-03T03:59:00.000Z", submitted: false, url: "https://www.gradescope.com/courses/123/assignments/456")])
let externalSnapshot = try payload.snapshot(now: now)
check(externalSnapshot.events.first?.date == instant("2026-10-03T03:59:00Z"), "bridge validates and preserves exact due")
var partial = externalSnapshot
partial.events = []
partial.fetchedAt = five
let merged = partial.merging(previous: externalSnapshot)
check(merged.events.count == 1 && merged.events[0].observedAt == now, "partial snapshot retains missing event without making it fresh")
var updatedSnapshot = externalSnapshot
updatedSnapshot.events[0].date = instant("2026-10-04T03:59:00Z")
updatedSnapshot.events[0].submitted = true
check(updatedSnapshot.merging(previous: externalSnapshot).events == updatedSnapshot.events, "changed due and submitted status replace same identity")
var secondCourse = payload
secondCourse.courseKey = "789"
secondCourse.events[0].url = "https://www.gradescope.com/courses/789/assignments/456"
let anotherSnapshot = try secondCourse.snapshot()
check(anotherSnapshot.events[0].id != externalSnapshot.events[0].id, "assignment IDs are scoped to course")
for mutation in 0..<5 {
    var bad = payload
    switch mutation {
    case 0: bad.source = "arbitrary"
    case 1: bad.events[0].url += "?token=private"
    case 2: bad.events[0].due = "not a date"
    case 3: bad.events.append(bad.events[0])
    default: bad.events[0].id = "../escape"
    }
    do { _ = try bad.snapshot(); check(false, "reject invalid external payload") }
    catch { check(true, "reject invalid external payload") }
}
let keenlyJSON = #"{"version":1,"source":"keenly","courseKey":"tasks","course":"Keenly Tasks","events":[{"id":"task_abc-123","title":"Exercise","course":"Programming","due":"2026-10-01","dateOnly":true,"submitted":false,"url":"https://keenly.study/tasks/task_abc-123"}],"completedIDs":[]}"#
do {
    let kp = try JSONDecoder().decode(ExternalPayload.self, from: Data(keenlyJSON.utf8))
    let ks = try kp.snapshot(now: now)
    check(ks.events[0].allDay && ks.events[0].course == "Programming", "Keenly date-only preserves task course")
    check(NYTime.dayKey(ks.events[0].date) == "2026-10-01", "Keenly calendar date does not shift across time zones")
    let doneJSON = #"{"version":1,"source":"keenly","courseKey":"tasks","course":"Keenly Tasks","events":[],"completedIDs":["task_abc-123"]}"#
    let done = try JSONDecoder().decode(ExternalPayload.self, from: Data(doneJSON.utf8)).snapshot(now: five)
    check(done.merging(previous: ks).events[0].submitted == true, "Keenly completed task without date clears existing reminder")
} catch { check(false, "Keenly source and date-only protocol accepted") }
let aleksJSON = #"{"version":1,"source":"aleks","courseKey":"Chemistry","course":"Chemistry","events":[{"id":"Homework 1","title":"Homework 1","due":"2026-11-03T04:59:00.000Z","submitted":true,"url":"https://www.aleks.com/"}]}"#
do {
    let payload = try JSONDecoder().decode(ExternalPayload.self, from: Data(aleksJSON.utf8))
    let snapshot = try payload.snapshot()
    check(snapshot.displayName == "ALEKS" && snapshot.events.first?.sourceName == "ALEKS", "ALEKS source labels")
    check(snapshot.events.first?.submitted == nil, "ALEKS does not infer submission")
} catch { check(false, "ALEKS snapshot accepted") }
print("\(checks) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
