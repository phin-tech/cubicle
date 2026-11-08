import XCTest

@testable import InstantSpaceSwitcher

final class CLIInstallerTests: XCTestCase {
  private var directory: URL!
  private var executable: URL!
  private var link: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("cli-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    executable = directory.appendingPathComponent("Cubicle.app/Contents/Helpers/cubicle")
    try FileManager.default.createDirectory(
      at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\n".utf8).write(to: executable)
    link = directory.appendingPathComponent("bin/cubicle")  // the bin folder does not exist yet
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  func testNothingThereMeansNotInstalled() {
    XCTAssertEqual(CLIInstaller.status(link: link, executable: executable), .notInstalled)
  }

  func testInstallCreatesTheFolderAndTheLink() throws {
    try CLIInstaller.install(link: link, executable: executable)
    XCTAssertEqual(CLIInstaller.status(link: link, executable: executable), .installed)
    XCTAssertEqual(
      try FileManager.default.destinationOfSymbolicLink(atPath: link.path), executable.path)
  }

  func testInstallingTwiceIsFine() throws {
    try CLIInstaller.install(link: link, executable: executable)
    try CLIInstaller.install(link: link, executable: executable)
    XCTAssertEqual(CLIInstaller.status(link: link, executable: executable), .installed)
  }

  func testLinkToAnotherCopyIsReportedAndCanBeUpdated() throws {
    let other = directory.appendingPathComponent("Other.app/Contents/Helpers/cubicle")
    try FileManager.default.createDirectory(
      at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\n".utf8).write(to: other)
    try CLIInstaller.install(link: link, executable: other)

    guard case .pointsElsewhere = CLIInstaller.status(link: link, executable: executable) else {
      return XCTFail("expected pointsElsewhere")
    }
    try CLIInstaller.install(link: link, executable: executable)
    XCTAssertEqual(CLIInstaller.status(link: link, executable: executable), .installed)
  }

  func testDanglingLinkIsBrokenAndCanBeRepaired() throws {
    let gone = directory.appendingPathComponent("Gone.app/Contents/Helpers/cubicle")
    try FileManager.default.createDirectory(
      at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: gone)

    guard case .broken = CLIInstaller.status(link: link, executable: executable) else {
      return XCTFail("expected broken")
    }
    try CLIInstaller.install(link: link, executable: executable)
    XCTAssertEqual(CLIInstaller.status(link: link, executable: executable), .installed)
  }

  func testARealFileInTheWayIsNeverOverwrittenOrDeleted() throws {
    try FileManager.default.createDirectory(
      at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("mine".utf8).write(to: link)

    XCTAssertEqual(CLIInstaller.status(link: link, executable: executable), .blocked)
    XCTAssertThrowsError(try CLIInstaller.install(link: link, executable: executable)) {
      XCTAssertEqual($0 as? CLIInstaller.InstallError, .blocked(link.path))
    }
    XCTAssertThrowsError(try CLIInstaller.uninstall(link: link))
    XCTAssertEqual(try String(contentsOf: link), "mine")
  }

  func testUninstallRemovesOnlyTheLink() throws {
    try CLIInstaller.install(link: link, executable: executable)
    try CLIInstaller.uninstall(link: link)
    XCTAssertEqual(CLIInstaller.status(link: link, executable: executable), .notInstalled)
    XCTAssertTrue(FileManager.default.fileExists(atPath: executable.path))
  }

  func testUninstallWhenNothingIsThereIsANoOp() throws {
    XCTAssertNoThrow(try CLIInstaller.uninstall(link: link))
  }
}
