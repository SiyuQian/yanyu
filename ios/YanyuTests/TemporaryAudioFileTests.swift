import XCTest

@testable import Yanyu

final class TemporaryAudioFileTests: XCTestCase {
  func testPendingRecoveryRecordingCanBeFoundAfterRestart() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let audioFile = try TemporaryAudioFile(recoveryIn: directory)
    try Data([1, 2, 3]).write(to: audioFile.url)
    let recoveredFile = try XCTUnwrap(
      TemporaryAudioFile.recoverPending(in: directory)
    )
    let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])

    XCTAssertEqual(recoveredFile.url, audioFile.url)
    XCTAssertEqual(values.isExcludedFromBackup, true)
    XCTAssertThrowsError(try TemporaryAudioFile(recoveryIn: directory)) { error in
      XCTAssertEqual(error as? TemporaryAudioFileError, .pendingRecordingExists)
    }
  }

  func testTemporaryFileUsesTheRequestedDirectoryAndCafExtension() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)

    let audioFile = try TemporaryAudioFile(in: directory)

    XCTAssertEqual(audioFile.url.deletingLastPathComponent(), directory)
    XCTAssertEqual(audioFile.url.pathExtension, "wav")
    try audioFile.remove()
    try FileManager.default.removeItem(at: directory)
  }

  func testRemoveDeletesRecordedAudio() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let audioFile = try TemporaryAudioFile(in: directory)
    try Data([1, 2, 3]).write(to: audioFile.url)

    try audioFile.remove()

    XCTAssertFalse(FileManager.default.fileExists(atPath: audioFile.url.path))
  }

  func testRemoveIsSafeWhenTheFileDoesNotExist() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let audioFile = try TemporaryAudioFile(in: directory)

    XCTAssertNoThrow(try audioFile.remove())
  }
}
