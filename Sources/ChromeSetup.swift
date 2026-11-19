import Foundation

enum ChromeSetup {
    static func register(bundle: URL = Bundle.main.bundleURL, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let executable = bundle.appendingPathComponent("Contents/MacOS/DDLBridge")
        guard !bundle.path.contains("/AppTranslocation/"), FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw NSError(domain: "ChromeSetup", code: 1, userInfo: [NSLocalizedDescriptionKey: "请先将 App 移到“应用程序”文件夹，再打开以连接 Chrome。"])
        }
        let directory = home.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = directory.appendingPathComponent("local.brightspace.ddl.json")
        let payload: [String: Any] = ["name": "local.brightspace.ddl", "description": "Local course deadline sync", "path": executable.path, "type": "stdio", "allowed_origins": [extensionOrigin]]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        if (try? Data(contentsOf: manifest)) != data { try data.write(to: manifest, options: .atomic) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
    }
}
