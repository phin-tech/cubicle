import Darwin
import Foundation

// MARK: - Messages

/// A command sent from the `cubicle` CLI to the running Cubicle app.
public struct CubicleRequest: Codable, Equatable {
  public var command: String
  public var argument: String?

  public init(command: String, argument: String? = nil) {
    self.command = command
    self.argument = argument
  }
}

public struct CubicleSpaceEntry: Codable, Equatable {
  public var display: String
  /// One-based position of the Space on its display.
  public var index: Int
  public var name: String?
  public var isCurrent: Bool

  public init(display: String, index: Int, name: String?, isCurrent: Bool) {
    self.display = display
    self.index = index
    self.name = name
    self.isCurrent = isCurrent
  }
}

public struct CubicleResponse: Codable, Equatable {
  public var ok: Bool
  public var message: String?
  public var spaces: [CubicleSpaceEntry]?

  public init(ok: Bool, message: String? = nil, spaces: [CubicleSpaceEntry]? = nil) {
    self.ok = ok
    self.message = message
    self.spaces = spaces
  }
}

public enum CubicleIPCError: Error, LocalizedError, Equatable {
  case notRunning
  case timedOut
  case invalidMessage
  case pathTooLong
  case alreadyRunning
  case system(String)

  public var errorDescription: String? {
    switch self {
    case .notRunning: return "Cubicle is not running."
    case .timedOut: return "Timed out waiting for Cubicle."
    case .invalidMessage: return "Received an invalid message."
    case .pathTooLong: return "The socket path is too long."
    case .alreadyRunning: return "Another Cubicle is already listening on this socket."
    case .system(let message): return message
    }
  }
}

// MARK: - Client

/// Cubicle and its CLI talk over a Unix domain socket in the user's Application Support folder.
/// The directory is created 0700 and the socket 0600, so only the same user can connect.
public enum CubicleIPC {
  public static let maximumMessageBytes = 64 * 1024

  public static var defaultSocketPath: String {
    NSHomeDirectory() + "/Library/Application Support/Cubicle/cubicle.sock"
  }

  /// Sends one request and waits for the reply. Throws `.notRunning` if nothing is listening.
  public static func send(
    _ request: CubicleRequest, socketPath: String = defaultSocketPath, timeout: Int = 5
  ) throws -> CubicleResponse {
    SocketIO.ignoreBrokenPipes()
    let fd = try SocketIO.connect(to: socketPath)
    defer { close(fd) }
    SocketIO.configure(fd, timeoutSeconds: timeout)

    var payload = try JSONEncoder().encode(request)
    payload.append(0x0A)
    try SocketIO.writeAll(fd, payload)
    let reply = try SocketIO.readMessage(fd)
    guard let response = try? JSONDecoder().decode(CubicleResponse.self, from: reply) else {
      throw CubicleIPCError.invalidMessage
    }
    return response
  }
}

// MARK: - Server

/// Listens for CLI requests. `handler` runs on the server's own queue, so hop to the main thread inside it
/// if it touches UI.
public final class CubicleIPCServer {
  private let path: String
  private let handler: (CubicleRequest) -> CubicleResponse
  private let queue = DispatchQueue(label: "tech.phin.cubicle.ipc")
  private var listenFD: Int32 = -1
  private var source: DispatchSourceRead?

  public init(
    socketPath: String = CubicleIPC.defaultSocketPath,
    handler: @escaping (CubicleRequest) -> CubicleResponse
  ) {
    self.path = socketPath
    self.handler = handler
  }

  deinit { stop() }

  public func start() throws {
    guard listenFD < 0 else { return }
    SocketIO.ignoreBrokenPipes()

    // Refuse to steal the socket from a live instance; a stale file from a crash is replaced.
    if let existing = try? SocketIO.connect(to: path) {
      close(existing)
      throw CubicleIPCError.alreadyRunning
    }

    let directory = (path as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(
      atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    unlink(path)

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw CubicleIPCError.system(String(cString: strerror(errno))) }

    var address = try SocketIO.address(for: path)
    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bound == 0 else {
      let message = String(cString: strerror(errno))
      close(fd)
      throw CubicleIPCError.system(message)
    }
    chmod(path, 0o600)
    guard listen(fd, 8) == 0 else {
      let message = String(cString: strerror(errno))
      close(fd)
      unlink(path)
      throw CubicleIPCError.system(message)
    }
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    source.setEventHandler { [weak self] in self?.acceptPending() }
    source.setCancelHandler { close(fd) }
    source.resume()
    self.source = source
    listenFD = fd
  }

  public func stop() {
    guard listenFD >= 0 else { return }
    source?.cancel()
    source = nil
    listenFD = -1
    unlink(path)
  }

  private func acceptPending() {
    while true {
      let client = accept(listenFD, nil, nil)
      if client < 0 { return }
      // Accepted sockets can inherit O_NONBLOCK from the listener; clients are handled with blocking I/O.
      _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
      SocketIO.configure(client, timeoutSeconds: 2)
      serve(client)
      close(client)
    }
  }

  private func serve(_ client: Int32) {
    let response: CubicleResponse
    do {
      let message = try SocketIO.readMessage(client)
      let request = try JSONDecoder().decode(CubicleRequest.self, from: message)
      response = handler(request)
    } catch {
      response = CubicleResponse(ok: false, message: "Invalid request.")
    }
    if var payload = try? JSONEncoder().encode(response) {
      payload.append(0x0A)
      try? SocketIO.writeAll(client, payload)
    }
  }
}

// MARK: - Socket helpers

enum SocketIO {
  /// A peer that hangs up mid-write must produce an error, not kill the process with SIGPIPE.
  /// Setting SO_NOSIGPIPE per socket is not enough: macOS rejects it on a connection that was already reset.
  static func ignoreBrokenPipes() {
    signal(SIGPIPE, SIG_IGN)
  }

  static func address(for path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
      throw CubicleIPCError.pathTooLong
    }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    return address
  }

  /// Returns a connected socket, or throws `.notRunning` when nothing is listening at `path`.
  static func connect(to path: String) throws -> Int32 {
    var address = try address(for: path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw CubicleIPCError.system(String(cString: strerror(errno))) }
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else {
      let code = errno
      close(fd)
      if code == ENOENT || code == ECONNREFUSED || code == ENOTSOCK { throw CubicleIPCError.notRunning }
      throw CubicleIPCError.system(String(cString: strerror(code)))
    }
    return fd
  }

  static func configure(_ fd: Int32, timeoutSeconds: Int) {
    var noSigPipe: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
  }

  static func writeAll(_ fd: Int32, _ data: Data) throws {
    try data.withUnsafeBytes { raw in
      var offset = 0
      while offset < raw.count {
        let written = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
        if written < 0 {
          if errno == EINTR { continue }
          if errno == EAGAIN || errno == EWOULDBLOCK { throw CubicleIPCError.timedOut }
          throw CubicleIPCError.system(String(cString: strerror(errno)))
        }
        offset += written
      }
    }
  }

  /// Reads up to the first newline (or EOF), refusing messages over `maximumMessageBytes`.
  static func readMessage(_ fd: Int32) throws -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = read(fd, &buffer, buffer.count)
      if count > 0 {
        if let newline = buffer[..<count].firstIndex(of: 0x0A) {
          data.append(contentsOf: buffer[..<newline])
          return data
        }
        data.append(contentsOf: buffer[..<count])
        if data.count > CubicleIPC.maximumMessageBytes { throw CubicleIPCError.invalidMessage }
      } else if count == 0 {
        return data
      } else {
        if errno == EINTR { continue }
        if errno == EAGAIN || errno == EWOULDBLOCK { throw CubicleIPCError.timedOut }
        throw CubicleIPCError.system(String(cString: strerror(errno)))
      }
    }
  }
}
