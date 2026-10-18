import Darwin
import Foundation

@main
@MainActor
struct FileSearchSessionPerformance {
    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }

    static func main() async throws {
        guard CommandLine.arguments.count == 3 else {
            print("Usage: file-search-session-performance --index|--on|--off INDEX_PATH")
            return
        }
        let policy = FileSearchPolicy(
            scopes: ["/Applications", "/System/Applications"], ignorePatterns: [],
            homeDirectory: URL(filePath: "/Users/benchmark"))
        let url = URL(filePath: CommandLine.arguments[2])
        if CommandLine.arguments[1] == "--index" {
            let roots = FileIndexCrawler.roots(of: policy)
            let listings = FileIndexCrawler.Crawl(roots: roots, policy: policy).run(workers: 4)
            try FileIndexSnapshot.write(listings, roots: roots, eventID: 0, fingerprint: policy.fingerprint, to: url)
            return
        }
        let enabled = CommandLine.arguments[1] == "--on"
        let index = FileIndex()
        guard let snapshot = FileIndexSnapshot(contentsOf: url) else { fatalError("unreadable index") }
        index.replace(with: snapshot, policy: policy)
        let session = FileSearchSession(index: index)
        var calls: [Double] = []
        var ready: [Double] = []
        let initial = residentBytes()
        for _ in 0..<20 {
            for query in ["swi", "swif", "swift", "info", "plist", "icon"] {
                let start = ContinuousClock.now
                if enabled { session.search(query) } else { session.cancel() }
                calls.append(milliseconds(start.duration(to: .now)))
                if enabled {
                    while session.state != .ready { try await Task.sleep(for: .milliseconds(1)) }
                }
                ready.append(milliseconds(start.duration(to: .now)))
            }
        }
        let searched = residentBytes()
        session.cancel()
        try await Task.sleep(for: .milliseconds(200))
        calls.sort()
        ready.sort()
        print("enabled=\(enabled) entries=\(index.itemCount)")
        print("call median=\(calls[60]) p95=\(calls[114]) ms")
        print("ready median=\(ready[60]) p95=\(ready[114]) ms")
        print("RSS initial=\(initial) searched=\(searched) closed=\(residentBytes()) bytes")
    }
}
