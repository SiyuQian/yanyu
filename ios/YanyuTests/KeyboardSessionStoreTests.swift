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

  func testHandledReceiptIsSharedAndDoesNotConsumeTheResult() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let app = KeyboardSessionStore(directory: directory)
    let keyboard = KeyboardSessionStore(directory: directory)
    let result = KeyboardSessionSnapshot(
      id: UUID(), phase: .ready, updatedAt: now, text: "你好 result")
    try app.write(result)
    XCTAssertFalse(try app.isResultHandled(for: result.id))

    try keyboard.markResultHandled(for: result.id, now: now)

    XCTAssertTrue(try app.isResultHandled(for: result.id))
    XCTAssertEqual(try app.read(now: now), result)
    let receipt = try Data(contentsOf: directory.appendingPathComponent("handled.json"))
    XCTAssertEqual(try JSONDecoder().decode(UUID.self, from: receipt), result.id)
  }

  func testStaleReceiptDoesNotHandleANewerResult() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let app = KeyboardSessionStore(directory: directory)
    let keyboard = KeyboardSessionStore(directory: directory)
    let first = KeyboardSessionSnapshot(id: UUID(), phase: .ready, updatedAt: now, text: "First")
    try app.write(first)
    try keyboard.markResultHandled(for: first.id, now: now)
    let second = KeyboardSessionSnapshot(id: UUID(), phase: .ready, updatedAt: now, text: "Second")
    try app.write(second)

    XCTAssertFalse(try app.isResultHandled(for: second.id))
    XCTAssertThrowsError(try keyboard.markResultHandled(for: first.id, now: now))
    XCTAssertFalse(try app.isResultHandled(for: second.id))
    XCTAssertEqual(try app.read(now: now), second)
  }

  func testOnlyCurrentUnexpiredReadyResultCanBeMarkedHandled() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let app = KeyboardSessionStore(directory: directory)
    let keyboard = KeyboardSessionStore(directory: directory)
    let id = UUID()
    try app.write(.init(id: id, phase: .recording, updatedAt: now))
    XCTAssertThrowsError(try keyboard.markResultHandled(for: id, now: now))
    try app.write(.init(id: id, phase: .ready, updatedAt: now, text: "Ready"))
    XCTAssertThrowsError(try keyboard.markResultHandled(for: UUID(), now: now))
    XCTAssertThrowsError(try keyboard.markResultHandled(for: id, now: now.addingTimeInterval(301)))
    XCTAssertFalse(try app.isResultHandled(for: id))
    try keyboard.markResultHandled(for: id, now: now.addingTimeInterval(300))
    XCTAssertTrue(try app.isResultHandled(for: id))
  }

  func testClearRemovesHandledReceiptAsWellAsResultAndStopRequest() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let app = KeyboardSessionStore(directory: directory)
    let keyboard = KeyboardSessionStore(directory: directory)
    let id = UUID()
    try app.write(.init(id: id, phase: .recording, updatedAt: now))
    try keyboard.requestStop(for: id, now: now)
    try app.write(.init(id: id, phase: .ready, updatedAt: now, text: "Saved"))
    try keyboard.markResultHandled(for: id, now: now)

    try app.clear()

    XCTAssertNil(try keyboard.read(now: now))
    XCTAssertFalse(try keyboard.stopRequested(for: id))
    XCTAssertFalse(try keyboard.isResultHandled(for: id))
  }

  func testCorruptReceiptIsReportedAndCorruptSnapshotCannotBeMarkedHandled() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let app = KeyboardSessionStore(directory: directory)
    let keyboard = KeyboardSessionStore(directory: directory)
    let result = KeyboardSessionSnapshot(id: UUID(), phase: .ready, updatedAt: now, text: "Keep me")
    try app.write(result)
    try Data("invalid".utf8).write(to: directory.appendingPathComponent("handled.json"))
    XCTAssertThrowsError(try app.isResultHandled(for: result.id))
    XCTAssertThrowsError(try keyboard.markResultHandled(for: result.id, now: now))
    XCTAssertEqual(try app.read(now: now), result)
    XCTAssertEqual(
      try Data(contentsOf: directory.appendingPathComponent("handled.json")), Data("invalid".utf8))
    try Data("invalid".utf8).write(to: directory.appendingPathComponent("session.json"))
    XCTAssertThrowsError(try keyboard.markResultHandled(for: result.id, now: now))
  }

  func testRepeatedHandlingDoesNotRewriteReceipt() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = KeyboardSessionStore(directory: directory)
    let id = UUID()
    try store.write(.init(id: id, phase: .ready, updatedAt: now, text: "Handled once"))
    try store.markResultHandled(for: id, now: now)
    let receiptURL = directory.appendingPathComponent("handled.json")
    let originalDate = Date(timeIntervalSince1970: 123)
    try FileManager.default.setAttributes(
      [.modificationDate: originalDate], ofItemAtPath: receiptURL.path)

    try store.markResultHandled(for: id, now: now.addingTimeInterval(1))

    let attributes = try FileManager.default.attributesOfItem(atPath: receiptURL.path)
    XCTAssertEqual(attributes[.modificationDate] as? Date, originalDate)
    XCTAssertTrue(try store.isResultHandled(for: id))
    XCTAssertThrowsError(try store.markResultHandled(for: id, now: now.addingTimeInterval(301)))
  }

}
