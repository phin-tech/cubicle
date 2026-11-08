import XCTest

@testable import CubicleIPC

final class CubicleIPCTests: XCTestCase {
  private func temporarySocketPath() -> String {
    NSTemporaryDirectory() + "cub-\(UUID().uuidString.prefix(8)).sock"
  }

  func testRequestAndResponseRoundTripOverSocket() throws {
    let path = temporarySocketPath()
    let server = CubicleIPCServer(socketPath: path) { request in
      CubicleResponse(
        ok: true, message: "got \(request.command) \(request.argument ?? "-")",
        spaces: [CubicleSpaceEntry(display: "Dell", index: 2, name: "Innopts", isCurrent: true)])
    }
    try server.start()
    defer { server.stop() }

    let response = try CubicleIPC.send(CubicleRequest(command: "go", argument: "ino"), socketPath: path)
    XCTAssertTrue(response.ok)
    XCTAssertEqual(response.message, "got go ino")
    XCTAssertEqual(response.spaces, [CubicleSpaceEntry(display: "Dell", index: 2, name: "Innopts", isCurrent: true)])
  }

  func testSendingToNothingReportsNotRunning() {
    XCTAssertThrowsError(try CubicleIPC.send(CubicleRequest(command: "list"), socketPath: temporarySocketPath())) {
      XCTAssertEqual($0 as? CubicleIPCError, .notRunning)
    }
  }

  func testSecondServerCannotStealALiveSocketButCanTakeItAfterStop() throws {
    let path = temporarySocketPath()
    let first = CubicleIPCServer(socketPath: path) { _ in CubicleResponse(ok: true, message: "first") }
    try first.start()

    let second = CubicleIPCServer(socketPath: path) { _ in CubicleResponse(ok: true, message: "second") }
    XCTAssertThrowsError(try second.start()) { XCTAssertEqual($0 as? CubicleIPCError, .alreadyRunning) }

    first.stop()
    try second.start()
    defer { second.stop() }
    XCTAssertEqual(try CubicleIPC.send(CubicleRequest(command: "x"), socketPath: path).message, "second")
  }

  func testStopRemovesSocketFile() throws {
    let path = temporarySocketPath()
    let server = CubicleIPCServer(socketPath: path) { _ in CubicleResponse(ok: true) }
    try server.start()
    XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    server.stop()
    XCTAssertFalse(FileManager.default.fileExists(atPath: path))
  }

  func testSocketIsOwnerOnly() throws {
    let path = temporarySocketPath()
    let server = CubicleIPCServer(socketPath: path) { _ in CubicleResponse(ok: true) }
    try server.start()
    defer { server.stop() }
    let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
    XCTAssertEqual(permissions, 0o600)
  }

  func testGarbageRequestGetsAnErrorResponseNotACrash() throws {
    let path = temporarySocketPath()
    let server = CubicleIPCServer(socketPath: path) { _ in CubicleResponse(ok: true) }
    try server.start()
    defer { server.stop() }

    let fd = try SocketIO.connect(to: path)
    defer { close(fd) }
    SocketIO.configure(fd, timeoutSeconds: 2)
    try SocketIO.writeAll(fd, Data("this is not json\n".utf8))
    let reply = try JSONDecoder().decode(CubicleResponse.self, from: SocketIO.readMessage(fd))
    XCTAssertFalse(reply.ok)
  }

  func testOverlongPathIsRejected() {
    let path = "/tmp/" + String(repeating: "a", count: 200)
    XCTAssertThrowsError(try CubicleIPC.send(CubicleRequest(command: "list"), socketPath: path)) {
      XCTAssertEqual($0 as? CubicleIPCError, .pathTooLong)
    }
  }

  func testRequestWithoutNewFieldsStillDecodes() throws {
    let legacy = Data(#"{"command":"list"}"#.utf8)
    let request = try JSONDecoder().decode(CubicleRequest.self, from: legacy)
    XCTAssertEqual(request, CubicleRequest(command: "list"))
    XCTAssertNil(request.here)
    XCTAssertNil(request.query)
  }

  func testListFiltersRoundTrip() throws {
    let request = CubicleRequest(command: "list", here: true, query: "ino")
    let decoded = try JSONDecoder().decode(CubicleRequest.self, from: JSONEncoder().encode(request))
    XCTAssertEqual(decoded, request)
  }
}
