import Foundation
import Network
import Synchronization

/// Raw TCP client sockets for the `node:net` shim: DNS, connect, reads and writes. JS owns
/// Node's event contract; Swift owns the wire, one `NWConnection` per socket. The app is not
/// sandboxed, so no entitlement governs this; loopback needs no local-network prompt either.
final class ExtensionSocketBridge: Sendable {
    private struct Connection {
        let connection: NWConnection
        var failure: Failure?
        var readEnded = false
        var writeEnded = false
    }

    private struct Failure: Error {
        let code: String
        let syscall: String
        let message: String
    }

    enum SocketError: LocalizedError {
        case badPort
        case cancelled
        case closed
        case unknown(String)

        var errorDescription: String? {
            switch self {
            case .badPort: return "Port should be >= 0 and < 65536."
            case .cancelled: return "The connection was closed while connecting."
            case .closed: return "The socket is closed."
            case .unknown(let method): return "Unknown host call 'socket.\(method)'."
            }
        }
    }

    private let connections = Mutex<[Int: Connection]>([:])
    private let attempts = Mutex<[Int: CheckedContinuation<Void, Error>]>([:])
    // A generation, not a flag: the palette reuses one bridge across commands, so `closeAll`
    // must abort only its own session's in-flight opens, never every future one.
    private let generation = Mutex(0)
    private let nextID = Mutex(1)
    private let queue = DispatchQueue(label: "pipcast.socket")

    func perform(method: String, arguments: [RenderValue]) async throws -> Any? {
        switch method {
        case "open": return try await open(arguments.first?.objectValue ?? [:])
        case "receive": return try await receive(id: whole(arguments.first))
        case "send": return try await send(arguments.first?.objectValue ?? [:])
        case "close":
            close(id: whole(arguments.first?.objectValue?["id"]))
            return nil
        default: throw SocketError.unknown(method)
        }
    }

    /// The context is thrown away between commands, so nothing left open outlives its session.
    func closeAll() {
        generation.withLock { $0 += 1 }
        let open = connections.withLock { state -> [Connection] in
            let all = Array(state.values)
            state.removeAll()
            return all
        }
        for connection in open { connection.connection.cancel() }
    }

    // MARK: - Calls

    private func open(_ fields: [String: RenderValue]) async throws -> [String: Any] {
        let host = fields["host"]?.stringValue ?? ""
        let port = whole(fields["port"], or: -1)
        guard (0..<65536).contains(port) else {
            return ["error": SocketError.badPort.localizedDescription, "code": "ERR_SOCKET_BAD_PORT"]
        }
        let family = whole(fields["family"])
        let id = nextID.withLock { value -> Int in
            defer { value += 1 }
            return value
        }
        let resolved = await Task.detached(priority: .userInitiated) {
            Self.resolve(host: host, family: family)
        }.value
        guard !resolved.isEmpty else {
            return [
                "error": "getaddrinfo ENOTFOUND \(host)", "code": "ENOTFOUND",
                "syscall": "getaddrinfo"
            ]
        }
        // Every resolved address gets a try, like Node's happy-eyeballs fallback in sequence.
        var lastFailure = Failure(
            code: "ECONNREFUSED", syscall: "connect", message: "connect ECONNREFUSED \(host):\(port)")
        let epoch = generation.withLock { $0 }
        for target in resolved {
            // A newer session started mid-loop: stop trying addresses for the dead one.
            if epoch != generation.withLock({ $0 }) { throw SocketError.cancelled }
            do {
                try await attempt(id: id, address: target.address, port: port)
                let info = connections.withLock { $0[id] }
                guard info != nil else { throw SocketError.cancelled }
                return [
                    "id": id, "address": target.address,
                    "family": target.ipv6 ? "IPv6" : "IPv4", "port": port
                ]
            } catch let failure as Failure {
                lastFailure = failure
            } catch {
                throw error
            }
        }
        connections.withLock { $0[id] = nil }
        return [
            "error": lastFailure.message, "code": lastFailure.code, "syscall": lastFailure.syscall
        ]
    }

    private func attempt(id: Int, address: String, port: Int) async throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw SocketError.badPort
        }
        let connection = NWConnection(
            host: NWEndpoint.Host(address), port: endpointPort, using: .tcp)
        connections.withLock { $0[id] = Connection(connection: connection) }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                attempts.withLock { $0[id] = continuation }
                connection.stateUpdateHandler = { [weak self] state in
                    self?.attemptState(id: id, state: state)
                }
                connection.start(queue: queue)
            }
        } catch {
            connections.withLock { $0[id] = nil }
            connection.stateUpdateHandler = nil
            connection.cancel()
            throw error
        }
    }

    private func attemptState(id: Int, state: NWConnection.State) {
        switch state {
        case .ready:
            resumeAttempt(id: id, result: .success(()))
        case .failed(let error):
            let failure = Self.failure(of: error, syscall: "connect")
            connections.withLock { $0[id]?.failure = failure }
            resumeAttempt(id: id, result: .failure(failure))
        case .waiting(let error):
            // A refused connection parks in `waiting` and never reaches `failed`; fail the
            // attempt fast instead of hanging the open call. Established connections keep
            // waiting (their reads stay pending under the socket's own timeout).
            guard attempts.withLock({ $0[id] }) != nil else { break }
            let failure = Self.failure(of: error, syscall: "connect")
            connections.withLock { $0[id]?.failure = failure }
            resumeAttempt(id: id, result: .failure(failure))
        case .cancelled:
            resumeAttempt(id: id, result: .failure(SocketError.cancelled))
        default:
            break
        }
    }

    private func resumeAttempt(id: Int, result: Result<Void, Error>) {
        let continuation = attempts.withLock { $0.removeValue(forKey: id) }
        continuation?.resume(with: result)
    }

    private func receive(id: Int) async throws -> [String: Any] {
        guard connections.withLock({ $0[id] }) != nil else { throw SocketError.closed }
        if let failure = connections.withLock({ $0[id]?.failure }) {
            return [
                "type": "close", "error": failure.message, "code": failure.code,
                "syscall": failure.syscall
            ]
        }
        if connections.withLock({ $0[id]?.readEnded }) == true {
            return ["type": "data", "base64": "", "end": true]
        }
        return await receiveChunk(id: id)
    }

    private func receiveChunk(id: Int) async -> [String: Any] {
        guard let connection = connections.withLock({ $0[id]?.connection }) else {
            return [
                "type": "close", "error": "The socket is closed.", "code": "ECONNABORTED",
                "syscall": "read"
            ]
        }
        return await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, complete, error in
                guard let self else {
                    continuation.resume(
                        returning: ["type": "close", "code": "ECONNABORTED", "syscall": "read"])
                    return
                }
                if let error {
                    let failure = Self.failure(of: error, syscall: "read")
                    self.connections.withLock { $0[id]?.failure = failure }
                    continuation.resume(
                        returning: [
                            "type": "close", "error": failure.message, "code": failure.code,
                            "syscall": failure.syscall
                        ])
                    return
                }
                if complete { self.connections.withLock { $0[id]?.readEnded = true } }
                continuation.resume(
                    returning: [
                        "type": "data", "base64": (content ?? Data()).base64EncodedString(),
                        "end": complete
                    ])
            }
        }
    }

    private func send(_ fields: [String: RenderValue]) async throws -> Any? {
        let id = whole(fields["id"])
        guard let connection = connections.withLock({ $0[id]?.connection }) else {
            throw SocketError.closed
        }
        if let failure = connections.withLock({ $0[id]?.failure }) {
            return ["error": failure.message, "code": failure.code, "syscall": failure.syscall]
        }
        let data = Data(base64Encoded: fields["base64"]?.stringValue ?? "") ?? Data()
        let final = fields["end"]?.boolValue == true
        return await withCheckedContinuation { continuation in
            // Every write is a complete message; `false` would hold the completion back.
            connection.send(
                content: data, contentContext: final ? .finalMessage : .defaultMessage,
                isComplete: true, completion: .contentProcessed { [weak self] error in
                    if final { self?.connections.withLock { $0[id]?.writeEnded = true } }
                    guard let error else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let failure = Self.failure(of: error, syscall: "write")
                    continuation.resume(
                        returning: [
                            "error": failure.message, "code": failure.code,
                            "syscall": failure.syscall
                        ])
                })
        }
    }

    private func close(id: Int) {
        guard let connection = connections.withLock({ $0.removeValue(forKey: id) }) else { return }
        connection.connection.cancel()
    }

    // MARK: - Resolution

    /// Blocking, hence the detached task. Literal-friendly: a numeric host resolves with no DNS.
    nonisolated private static func resolve(host: String, family: Int) -> [(address: String, ipv6: Bool)] {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        if family == 4 { hints.ai_family = AF_INET } else if family == 6 { hints.ai_family = AF_INET6 }
        var head: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &head) == 0, let first = head else { return [] }
        defer { freeaddrinfo(first) }
        var found: [(address: String, ipv6: Bool)] = []
        var entry: UnsafeMutablePointer<addrinfo>? = first
        while let current = entry {
            var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(
                current.pointee.ai_addr, current.pointee.ai_addrlen, &text, socklen_t(text.count),
                nil, 0, NI_NUMERICHOST) == 0
            {
                let digits = text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                let address = String(decoding: digits, as: UTF8.self)
                let ipv6 = current.pointee.ai_family == AF_INET6
                if !found.contains(where: { $0.address == address }) {
                    found.append((address, ipv6))
                }
            }
            entry = current.pointee.ai_next
        }
        return found
    }

    // MARK: - Errors

    nonisolated private static func failure(of error: NWError, syscall: String) -> Failure {
        switch error {
        case .posix(let code):
            let name = posixName(code.rawValue)
            return Failure(
                code: name, syscall: syscall,
                message: "\(syscall) \(name): \(String(cString: strerror(code.rawValue)))")
        case .dns:
            return Failure(code: "ENOTFOUND", syscall: "getaddrinfo", message: "getaddrinfo ENOTFOUND")
        default:
            return Failure(code: "EIO", syscall: syscall, message: error.localizedDescription)
        }
    }

    nonisolated private static func posixName(_ code: Int32) -> String {
        switch code {
        case ECONNREFUSED: return "ECONNREFUSED"
        case ETIMEDOUT: return "ETIMEDOUT"
        case EHOSTUNREACH: return "EHOSTUNREACH"
        case ENETUNREACH: return "ENETUNREACH"
        case EHOSTDOWN: return "EHOSTDOWN"
        case ENETDOWN: return "ENETDOWN"
        case EACCES, EPERM: return "EACCES"
        case EADDRNOTAVAIL: return "EADDRNOTAVAIL"
        case EPIPE: return "EPIPE"
        case ECONNRESET: return "ECONNRESET"
        case ECONNABORTED: return "ECONNABORTED"
        default: return "EIO"
        }
    }

    private func whole(_ value: RenderValue?, or fallback: Int = 0) -> Int {
        value?.doubleValue.flatMap(Int.init(exactly:)) ?? fallback
    }
}
