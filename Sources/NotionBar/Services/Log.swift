import Foundation

/// A small diagnostics log at `~/Library/Logs/NotionBar.log`.
///
/// It records what the app asked Notion for and what came back (counts, timings, error messages,
/// page ids), so a problem with the real Notion can be looked at afterwards. It never contains
/// the token, and it doesn't record task names. Settings → "Show log" opens it.
enum Log {
    static let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/NotionBar.log")

    /// Off for demo mode, the self-test and snapshots, so only real use is recorded.
    static var isEnabled = false

    private static let queue = DispatchQueue(label: "local.notionbar.log", qos: .utility)
    private static let maxBytes = 200_000

    static func write(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let line = "\(stamp(Date()))  \(message())\n"
        queue.async {
            let manager = FileManager.default
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !manager.fileExists(atPath: url.path) {
                manager.createFile(atPath: url.path, contents: nil)
            }
            // Keep it small: once it passes the limit, drop the older half.
            if let size = try? manager.attributesOfItem(atPath: url.path)[.size] as? Int, size > maxBytes,
               let data = try? Data(contentsOf: url) {
                let tail = data.suffix(maxBytes / 2)
                let cut = tail.firstIndex(of: UInt8(ascii: "\n")).map { tail.index(after: $0) } ?? tail.startIndex
                try? Data(tail[cut...]).write(to: url, options: .atomic)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }

    private static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }
}
