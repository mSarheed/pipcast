import Darwin
import Foundation
import Synchronization

// Guards the raw TCP bridge behind a loopback echo server: connect, echo, half-close,
// refusal, unknown hosts and session teardown. The JS contract itself is covered by
// `Scripts/raycast-runtime/fixtures.mjs`, which drives the same calls through the harness.
enum ExtensionSocketTests {
    static func runChecks() async {
        let server = EchoServer()
        await server.start()
        let bridge = ExtensionSocketBridge()
        await openEchoClose(bridge: bridge, port: server.port)
        await refused(bridge: bridge)
        await unknownHost(bridge: bridge)
        await localhostFallback(bridge: bridge, port: server.port)
        await teardown(bridge: bridge, port: server.port)
        await server.stop()
    }

    private static func openEchoClose(bridge: ExtensionSocketBridge, port: Int) async {
        let opened = try? await bridge.perform(
            method: "open",
            arguments: [.object(["host": .string("127.0.0.1"), "port": .number(Double(port))])])
        let fields = opened as? [String: Any] ?? [:]
        guard let id = fields["id"] as? Int else {
            ExtensionTests.check("opening the echo server reports an id", false, String(describing: fields))
            return
        }
        ExtensionTests.check(
            "opening reports the loopback peer", fields["address"] as? String == "127.0.0.1",
            String(describing: fields))
        _ = try? await bridge.perform(
            method: "send",
            arguments: [.object(["id": .number(Double(id)), "base64": .string(Data("ping".utf8).base64EncodedString())])])
        let first = try? await bridge.perform(method: "receive", arguments: [.number(Double(id))])
        let chunk = (first as? [String: Any] ?? [:])["base64"] as? String
        ExtensionTests.check(
            "a write echoes back through the socket",
            Data(base64Encoded: chunk ?? "") == Data("ping".utf8), String(describing: first))
        _ = try? await bridge.perform(
            method: "send",
            arguments: [.object(["id": .number(Double(id)), "base64": .string(""), "end": .bool(true)])])
        let last = try? await bridge.perform(method: "receive", arguments: [.number(Double(id))])
        let end = (last as? [String: Any] ?? [:])["end"] as? Bool
        ExtensionTests.check("the server FIN arrives as an end event", end == true, String(describing: last))
        _ = try? await bridge.perform(
            method: "close", arguments: [.object(["id": .number(Double(id))])])
    }

    private static func refused(bridge: ExtensionSocketBridge) async {
        let result = try? await bridge.perform(
            method: "open",
            arguments: [.object(["host": .string("127.0.0.1"), "port": .number(1)])])
        let fields = result as? [String: Any] ?? [:]
        ExtensionTests.check(
            "a closed port refuses with its code", fields["code"] as? String == "ECONNREFUSED",
            String(describing: fields))
    }

    private static func unknownHost(bridge: ExtensionSocketBridge) async {
        let result = try? await bridge.perform(
            method: "open",
            arguments: [.object(["host": .string("missing.invalid"), "port": .number(80)])])
        let fields = result as? [String: Any] ?? [:]
        ExtensionTests.check(
            "an unresolvable host reports ENOTFOUND", fields["code"] as? String == "ENOTFOUND",
            String(describing: fields))
    }

    private static func localhostFallback(bridge: ExtensionSocketBridge, port: Int) async {
        let result = try? await bridge.perform(
            method: "open",
            arguments: [.object(["host": .string("localhost"), "port": .number(Double(port))])])
        let fields = result as? [String: Any] ?? [:]
        if let id = fields["id"] as? Int {
            ExtensionTests.check("localhost reaches the IPv4 echo server", true)
            _ = try? await bridge.perform(
                method: "close", arguments: [.object(["id": .number(Double(id))])])
        } else {
            ExtensionTests.check(
                "localhost reaches the IPv4 echo server", false, String(describing: fields))
        }
    }

    private static func teardown(bridge: ExtensionSocketBridge, port: Int) async {
        let opened = try? await bridge.perform(
            method: "open",
            arguments: [.object(["host": .string("127.0.0.1"), "port": .number(Double(port))])])
        let id = (opened as? [String: Any] ?? [:])["id"] as? Int ?? -1
        bridge.closeAll()
        do {
            _ = try await bridge.perform(method: "receive", arguments: [.number(Double(id))])
            ExtensionTests.check("teardown releases open sockets", false, "receive still answered")
        } catch {
            ExtensionTests.check("teardown releases open sockets", true)
        }
        // The palette reuses one bridge across commands: the next session opens cleanly.
        let reopened = try? await bridge.perform(
            method: "open",
            arguments: [.object(["host": .string("127.0.0.1"), "port": .number(Double(port))])])
        let reopenedID = (reopened as? [String: Any] ?? [:])["id"] as? Int
        ExtensionTests.check("a later session opens after teardown", reopenedID != nil, String(describing: reopened))
        if let reopenedID {
            _ = try? await bridge.perform(
                method: "close", arguments: [.object(["id": .number(Double(reopenedID))])])
        }
    }
}

/// A loopback echo server on an ephemeral port, speaking raw POSIX so the test needs no harness.
private final class EchoServer: Sendable {
    private let listener: Mutex<Int32> = Mutex(-1)
    private let portBox: Mutex<Int> = Mutex(0)
    var port: Int { portBox.withLock { $0 } }

    func start() async {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var reuse: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 8) == 0 else {
            Darwin.close(fd)
            return
        }
        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &boundAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = getsockname(fd, $0, &length)
            }
        }
        portBox.withLock { $0 = Int(CFSwapInt16BigToHost(boundAddress.sin_port)) }
        listener.withLock { $0 = fd }
        Task.detached { [weak self] in self?.acceptLoop(fd: fd) }
    }

    func stop() async {
        let fd = listener.withLock { value -> Int32 in
            defer { value = -1 }
            return value
        }
        // Wakes the blocking `accept` so the loop exits instead of lingering.
        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
    }

    private func acceptLoop(fd: Int32) {
        while true {
            let peer = Darwin.accept(fd, nil, nil)
            if peer < 0 { return }
            Task.detached { Self.echo(peer: peer) }
        }
    }

    private static func echo(peer: Int32) {
        defer { Darwin.close(peer) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.recv(peer, &buffer, buffer.count, 0)
            if count <= 0 { return }
            var sent = 0
            while sent < count {
                let step = buffer.withUnsafeBytes {
                    Darwin.send(peer, $0.baseAddress!.advanced(by: sent), count - sent, 0)
                }
                if step <= 0 { return }
                sent += step
            }
        }
    }
}
