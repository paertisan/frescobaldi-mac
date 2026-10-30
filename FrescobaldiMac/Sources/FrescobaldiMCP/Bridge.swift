import Darwin
import Foundation

/// The connection between `frescobaldi-mcp` and the running app: a Unix
/// domain socket in the user's Application Support folder (owner-only
/// permissions, and the app checks the peer's user id).
///
/// One request per connection, each a line of JSON:
///
///     → {"method": "getDocument", "params": {...}}
///     ← {"result": ...}   or   {"error": "message"}
public enum Bridge {
    public static var socketPath: String {
        if let path = ProcessInfo.processInfo.environment["FRESCOBALDI_BRIDGE_SOCKET"], !path.isEmpty {
            return path
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Frescobaldi/bridge.sock").path
    }

    public static let notRunningMessage =
        "Frescobaldi isn't running, or Claude access is off (Frescobaldi > Settings > Claude)."
}

public struct BridgeError: Error, LocalizedError, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

// MARK: - Sockets

private func makeAddress(_ path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = path.utf8CString
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        throw BridgeError("The socket path is too long: \(path)")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        bytes.withUnsafeBytes { buffer.copyMemory(from: $0) }
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return address
}

private func newSocket() throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw BridgeError("socket() failed: \(String(cString: strerror(errno)))") }
    var on: Int32 = 1
    // A peer that goes away must not kill us with SIGPIPE.
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    return fd
}

private func setTimeout(_ fd: Int32, _ seconds: TimeInterval) {
    var time = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - seconds.rounded(.down)) * 1_000_000))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
}

private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
            let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
            if written < 0 {
                if errno == EINTR { continue }
                return false
            }
            offset += written
        }
        return true
    }
}

/// Reads up to the first newline (or EOF). Nil on error or timeout.
private func readLine(_ fd: Int32, limit: Int = 64 << 20) -> Data? {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 65536)
    while data.count < limit {
        let count = read(fd, &buffer, buffer.count)
        if count < 0 {
            if errno == EINTR { continue }
            return nil
        }
        if count == 0 { return data.isEmpty ? nil : data }
        if let newline = buffer[0..<count].firstIndex(of: 0x0A) {
            data.append(contentsOf: buffer[0..<newline])
            return data
        }
        data.append(contentsOf: buffer[0..<count])
    }
    return nil
}

// MARK: - Client

public struct BridgeClient: Sendable {
    public var socketPath: String

    public init(socketPath: String = Bridge.socketPath) {
        self.socketPath = socketPath
    }

    /// Sends one request and waits for the answer. Blocks.
    public func call(_ method: String, _ params: JSONValue = .object([:]),
                     timeout: TimeInterval = 30) throws -> JSONValue {
        let fd = try newSocket()
        defer { close(fd) }
        var address = try makeAddress(socketPath)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw BridgeError(Bridge.notRunningMessage) }
        setTimeout(fd, timeout)
        let request: JSONValue = ["method": .string(method), "params": params]
        guard writeAll(fd, request.encoded() + Data([0x0A])) else {
            throw BridgeError("Couldn't send the request to Frescobaldi.")
        }
        guard let line = readLine(fd) else {
            throw BridgeError("Frescobaldi didn't answer within \(Int(timeout)) seconds.")
        }
        let response = try JSONValue.parse(line)
        if let message = response["error"]?.string { throw BridgeError(message) }
        return response["result"] ?? .null
    }

    /// True if the app is listening.
    public var isAvailable: Bool {
        (try? call("ping", timeout: 2)) != nil
    }
}

// MARK: - Server

/// The app's side. Each request is passed to `handler` with a reply
/// function, which may be called later from any thread (once).
public final class BridgeServer: @unchecked Sendable {
    public typealias Reply = @Sendable (Result<JSONValue, Error>) -> Void
    public typealias Handler = @Sendable (_ method: String, _ params: JSONValue, _ reply: @escaping Reply) -> Void

    public let socketPath: String
    private let handler: Handler
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "BridgeServer", attributes: .concurrent)

    public init(socketPath: String = Bridge.socketPath, handler: @escaping Handler) {
        self.socketPath = socketPath
        self.handler = handler
    }

    deinit { stop() }

    public var isRunning: Bool { source != nil }

    public func start() throws {
        guard source == nil else { return }
        let directory = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // A socket left behind by a crash: remove it, unless something answers.
        if FileManager.default.fileExists(atPath: socketPath) {
            if BridgeClient(socketPath: socketPath).isAvailable {
                throw BridgeError("Another Frescobaldi is already serving \(socketPath).")
            }
            unlink(socketPath)
        }

        let fd = try newSocket()
        var address = try makeAddress(socketPath)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw BridgeError("Couldn't open \(socketPath): \(message)")
        }
        chmod(socketPath, 0o600)
        guard listen(fd, 16) == 0 else {
            close(fd)
            unlink(socketPath)
            throw BridgeError("listen() failed: \(String(cString: strerror(errno)))")
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listener = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptConnections() }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
    }

    public func stop() {
        guard let source else { return }
        self.source = nil
        source.cancel()
        listener = -1
        unlink(socketPath)
    }

    private func acceptConnections() {
        while true {
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { return } // EAGAIN: no more pending
            queue.async { [weak self] in self?.serve(connection) }
        }
    }

    private func serve(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
            close(fd)
            return
        }
        setTimeout(fd, 10)
        guard let line = readLine(fd), let request = try? JSONValue.parse(line),
              let method = request["method"]?.string else {
            _ = writeAll(fd, (["error": "Bad request"] as JSONValue).encoded() + Data([0x0A]))
            close(fd)
            return
        }
        let once = OnceFlag()
        let reply: Reply = { result in
            guard once.claim() else { return }
            let response: JSONValue
            switch result {
            case let .success(value): response = ["result": value]
            case let .failure(error): response = ["error": .string(error.localizedDescription)]
            }
            _ = writeAll(fd, response.encoded() + Data([0x0A]))
            close(fd)
        }
        if method == "ping" {
            reply(.success(["pong": true]))
        } else {
            handler(method, request["params"] ?? .object([:]), reply)
        }
    }
}

/// True the first time only, from any thread.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}
