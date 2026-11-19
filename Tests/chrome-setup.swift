import Foundation

@main struct ChromeSetupChecks {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let home = root.appendingPathComponent("User Home")
        for name in ["Applications/DDL.app", "Moved Apps/DDL.app"] {
            let bundle = root.appendingPathComponent(name)
            let executable = bundle.appendingPathComponent("Contents/MacOS/DDLBridge")
            try fm.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("test".utf8).write(to: executable)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            try ChromeSetup.register(bundle: bundle, home: home)
            let path = home.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts/local.brightspace.ddl.json")
            let value = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
            precondition(value["path"] as? String == executable.path)
            precondition(value["allowed_origins"] as? [String] == [extensionOrigin])
            let mode = try fm.attributesOfItem(atPath: path.path)[.posixPermissions] as! NSNumber
            precondition(mode.intValue == 0o600)
        }
        do {
            try ChromeSetup.register(bundle: root.appendingPathComponent("Missing.app"), home: home)
            fatalError("Missing bridge must fail")
        } catch { }
        print("Chrome registration checks passed: custom path, moved app, origin, permissions, missing bridge")
    }
}
