import XCTest

@testable import Yanyu

final class KeyboardResultConsumerTests: XCTestCase {
  func testInsertingResultOncePreventsRepeatAfterKeyboardRelaunch() throws {
    let suite = "KeyboardResultConsumerTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let result = KeyboardSessionSnapshot(id: UUID(), phase: .ready, updatedAt: .now, text: "你好")
    let first = KeyboardResultConsumer(defaults: defaults)
    XCTAssertEqual(first.consume(result), "你好")
    let relaunched = KeyboardResultConsumer(defaults: defaults)
    XCTAssertNil(relaunched.consume(result))
    let next = KeyboardSessionSnapshot(id: UUID(), phase: .ready, updatedAt: .now, text: "Next")
    XCTAssertEqual(relaunched.consume(next), "Next")
  }

  func testPartialOrExpiredTranscriptionCannotBeInserted() throws {
    let suite = "KeyboardResultConsumerTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let consumer = KeyboardResultConsumer(defaults: defaults)
    XCTAssertNil(
      consumer.consume(.init(id: UUID(), phase: .failed, updatedAt: .now, text: "Partial")))
    XCTAssertNil(
      consumer.consume(
        .init(id: UUID(), phase: .ready, updatedAt: .now.addingTimeInterval(-301), text: "Old")))
  }
}
