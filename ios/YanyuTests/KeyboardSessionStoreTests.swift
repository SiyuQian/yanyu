import XCTest

@testable import Yanyu

final class KeyboardSessionStoreTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_000)

  func testAppResultIsReadableByAnotherStoreButExpires() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let app = KeyboardSessionStore(directory: directory)
    let keyboard = KeyboardSessionStore(directory: directory)
    let snapshot = KeyboardSessionSnapshot(
      id: UUID(), phase: .ready, updatedAt: now, text: "你好 Yanyu")
    try app.write(snapshot)
    XCTAssertEqual(try keyboard.read(now: now)?.text, "你好 Yanyu")
    XCTAssertNil(try keyboard.read(now: now.addingTimeInterval(301)))
  }

  func testStopCommandCannotStopANewerRecording() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let app = KeyboardSessionStore(directory: directory)
    let keyboard = KeyboardSessionStore(directory: directory)
    let first = KeyboardSessionSnapshot(id: UUID(), phase: .recording, updatedAt: now)
    try app.write(first)
    try keyboard.requestStop(for: first.id, now: now)
    XCTAssertTrue(try app.stopRequested(for: first.id))
    let second = KeyboardSessionSnapshot(id: UUID(), phase: .recording, updatedAt: now)
    try app.write(second)
    XCTAssertFalse(try app.stopRequested(for: second.id))
    XCTAssertThrowsError(try keyboard.requestStop(for: first.id, now: now))
  }

  func testDeadAppHeartbeatDoesNotLookLikeLiveRecording() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = KeyboardSessionStore(directory: directory)
    let snapshot = KeyboardSessionSnapshot(id: UUID(), phase: .recording, updatedAt: now)
    try store.write(snapshot)
    XCTAssertNil(try store.read(now: now.addingTimeInterval(6)))
    XCTAssertThrowsError(try store.requestStop(for: snapshot.id, now: now.addingTimeInterval(6)))
  }

  func testClearingSessionRemovesSharedTextAndCommand() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = KeyboardSessionStore(directory: directory)
    let snapshot = KeyboardSessionSnapshot(id: UUID(), phase: .recording, updatedAt: now)
    try store.write(snapshot)
    try store.requestStop(for: snapshot.id, now: now)
    try store.clear()
    XCTAssertNil(try store.read(now: now))
    XCTAssertFalse(try store.stopRequested(for: snapshot.id))
  }

  func testCorruptSharedDataIsReportedRatherThanInserted() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = KeyboardSessionStore(directory: directory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("invalid".utf8).write(to: directory.appendingPathComponent("session.json"))
    XCTAssertThrowsError(try store.read(now: now))
  }
}
