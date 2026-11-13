import Foundation
import Darwin

func readExactly(_ count: Int) -> Data? {
    var result = Data()
    while result.count < count {
        let part = FileHandle.standardInput.readData(ofLength: count - result.count)
        if part.isEmpty { return nil }
        result.append(part)
    }
    return result
}
func reply(_ ok: Bool) {
    let body = Data((ok ? "{\"ok\":true}" : "{\"ok\":false}").utf8)
    var length = UInt32(body.count).littleEndian
    FileHandle.standardOutput.write(Data(bytes: &length, count: 4))
    FileHandle.standardOutput.write(body)
}
guard CommandLine.arguments.dropFirst().first == extensionOrigin,
      let header = readExactly(4) else { exit(1) }
let length = header.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
guard length > 0, length <= 1_000_000, let data = readExactly(Int(length)) else { reply(false); exit(1) }
do {
    let payload = try JSONDecoder().decode(ExternalPayload.self, from: data)
    let snapshot = try payload.snapshot()
    let directory = ExternalSnapshot.directory
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let lock = open(directory.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o600)
    guard lock >= 0, flock(lock, LOCK_EX) == 0 else { throw ICS.Failure.invalid }
    defer { flock(lock, LOCK_UN); close(lock) }
    let destination = directory.appendingPathComponent(snapshot.id + ".json")
    var previous: ExternalSnapshot?
    if FileManager.default.fileExists(atPath: destination.path) {
        previous = try JSONDecoder().decode(ExternalSnapshot.self, from: Data(contentsOf: destination))
    }
    try JSONEncoder().encode(snapshot.merging(previous: previous)).write(to: destination, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    reply(true)
} catch { reply(false); exit(1) }
