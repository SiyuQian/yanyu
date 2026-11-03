import UIKit
import XCTest

@testable import Yanyu

final class KeyboardResultConsumerTests: XCTestCase {
  @MainActor
  func testReadyResultAutomaticallyInsertsOnlyOnceIntoTheOriginalField() throws {
    let defaults = try isolatedDefaults()
    defer { defaults.0.removePersistentDomain(forName: defaults.1) }
    let delivery = KeyboardTextDelivery(defaults: defaults.0)
    let document = KeyboardTestDocument(text: "Draft: ")
    let result = KeyboardSessionSnapshot(id: UUID(), phase: .ready, updatedAt: .now, text: "你好")
    delivery.prepareAutomaticInsertion(for: result.id, in: document.context)

    XCTAssertTrue(delivery.insert(result, into: document, automatically: true))
    XCTAssertEqual(document.view.text, "Draft: 你好")
    XCTAssertFalse(delivery.insert(result, into: document, automatically: true))
    XCTAssertTrue(delivery.canUndo(in: document.context))
    let recreated = KeyboardTextDelivery(defaults: defaults.0)
    XCTAssertFalse(recreated.insert(result, into: document))
    XCTAssertEqual(document.view.text, "Draft: 你好")
  }

  @MainActor
  func testChangedFieldKeepsResultForExplicitInsertionInsteadOfAutomaticDelivery() throws {
    let defaults = try isolatedDefaults()
    defer { defaults.0.removePersistentDomain(forName: defaults.1) }
    let delivery = KeyboardTextDelivery(defaults: defaults.0)
    let document = KeyboardTestDocument(text: "Original draft")
    let result = KeyboardSessionSnapshot(id: UUID(), phase: .ready, updatedAt: .now, text: "Hello")
    delivery.prepareAutomaticInsertion(for: result.id, in: document.context)
    document.identifier = UUID()

    XCTAssertFalse(delivery.insert(result, into: document, automatically: true))
    XCTAssertEqual(document.view.text, "Original draft")
    XCTAssertTrue(delivery.insert(result, into: document))
    XCTAssertEqual(document.view.text, "Original draftHello")
  }

  @MainActor
  func testEditingOrMovingTheCursorRequiresManualDeliveryAndInvalidatesUndo() throws {
    let defaults = try isolatedDefaults()
    defer { defaults.0.removePersistentDomain(forName: defaults.1) }
    let delivery = KeyboardTextDelivery(defaults: defaults.0)
    let document = KeyboardTestDocument(text: "Draft")
    let result = KeyboardSessionSnapshot(
      id: UUID(), phase: .ready, updatedAt: .now, text: " speech")
    delivery.prepareAutomaticInsertion(for: result.id, in: document.context)
    document.view.insertText(" typed")
    XCTAssertFalse(delivery.insert(result, into: document, automatically: true))
    XCTAssertEqual(document.view.text, "Draft typed")
    XCTAssertTrue(delivery.insert(result, into: document))
    document.view.selectedRange = NSRange(location: 0, length: 0)
    XCTAssertFalse(delivery.undo(in: document))
    XCTAssertEqual(document.view.text, "Draft typed speech")
  }

  @MainActor
  func testUndoRemovesOnlyTheInsertedBilingualTextAndCannotBeRepeated() throws {
    let defaults = try isolatedDefaults()
    defer { defaults.0.removePersistentDomain(forName: defaults.1) }
    let delivery = KeyboardTextDelivery(defaults: defaults.0)
    let document = KeyboardTestDocument(text: "Existing draft: ")
    let result = KeyboardSessionSnapshot(
      id: UUID(), phase: .ready, updatedAt: .now, text: "你好 café 👨‍👩‍👧‍👦")

    XCTAssertTrue(delivery.insert(result, into: document))
    XCTAssertTrue(delivery.canUndo(in: document.context))
    XCTAssertTrue(delivery.undo(in: document))
    XCTAssertEqual(document.view.text, "Existing draft: ")
    XCTAssertFalse(delivery.undo(in: document))
  }

  @MainActor
  func testHiddenKeyboardAndUnavailableContextNeverAutomaticallyInsert() throws {
    let defaults = try isolatedDefaults()
    defer { defaults.0.removePersistentDomain(forName: defaults.1) }
    let delivery = KeyboardTextDelivery(defaults: defaults.0)
    let document = KeyboardTestDocument(text: "Keep")
    let result = KeyboardSessionSnapshot(
      id: UUID(), phase: .ready, updatedAt: .now, text: " speech")
    delivery.prepareAutomaticInsertion(for: result.id, in: document.context)
    delivery.invalidateContext()
    XCTAssertFalse(delivery.insert(result, into: document, automatically: true))
    document.exposesContext = false
    delivery.prepareAutomaticInsertion(for: result.id, in: document.context)
    XCTAssertFalse(delivery.insert(result, into: document, automatically: true))
    XCTAssertEqual(document.view.text, "Keep")
    XCTAssertTrue(delivery.insert(result, into: document))
    XCTAssertFalse(delivery.canUndo(in: document.context))
  }

  @MainActor
  func testUndoIsUnavailableWhenInsertionChangesAnExistingGrapheme() throws {
    let defaults = try isolatedDefaults()
    defer { defaults.0.removePersistentDomain(forName: defaults.1) }
    let delivery = KeyboardTextDelivery(defaults: defaults.0)
    let document = KeyboardTestDocument(text: "a")
    let result = KeyboardSessionSnapshot(
      id: UUID(), phase: .ready, updatedAt: .now, text: "\u{0301}")
    XCTAssertTrue(delivery.insert(result, into: document))
    XCTAssertFalse(delivery.canUndo(in: document.context))
    XCTAssertFalse(delivery.undo(in: document))
    XCTAssertEqual(document.view.text, "a\u{0301}")
  }

  private func isolatedDefaults() throws -> (UserDefaults, String) {
    let suite = "KeyboardTextDeliveryTests.\(UUID().uuidString)"
    return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
  }

  @MainActor
  func testUndoDoesNotRemoveAnExistingSuffixThatJoinsTheInsertedGrapheme() throws {
    let defaults = try isolatedDefaults()
    defer { defaults.0.removePersistentDomain(forName: defaults.1) }
    let delivery = KeyboardTextDelivery(defaults: defaults.0)
    let document = KeyboardTestDocument(text: "\u{0301}")
    document.view.selectedRange = NSRange(location: 0, length: 0)
    let result = KeyboardSessionSnapshot(id: UUID(), phase: .ready, updatedAt: .now, text: "e")

    XCTAssertTrue(delivery.insert(result, into: document))
    XCTAssertFalse(delivery.canUndo(in: document.context))
    XCTAssertFalse(delivery.undo(in: document))
    XCTAssertEqual(document.view.text, "e\u{0301}")
  }

  @MainActor
  func testUndoDoesNotSplitAnExistingRegionalIndicatorWhenCharacterCountsMatch() throws {
    let defaults = try isolatedDefaults()
    defer { defaults.0.removePersistentDomain(forName: defaults.1) }
    let delivery = KeyboardTextDelivery(defaults: defaults.0)
    let document = KeyboardTestDocument(text: "\u{1F1FA}")
    let result = KeyboardSessionSnapshot(
      id: UUID(), phase: .ready, updatedAt: .now, text: "\u{1F1F8}\u{1F1EC}")

    XCTAssertTrue(delivery.insert(result, into: document))
    XCTAssertFalse(delivery.canUndo(in: document.context))
    XCTAssertFalse(delivery.undo(in: document))
    XCTAssertEqual(document.view.text, "\u{1F1FA}\u{1F1F8}\u{1F1EC}")
  }

  @MainActor
  func testSelectedTextIsReplacedOnlyAfterExplicitInsertionWithoutDestructiveUndo() throws {
    let defaults = try isolatedDefaults()
    defer { defaults.0.removePersistentDomain(forName: defaults.1) }
    let delivery = KeyboardTextDelivery(defaults: defaults.0)
    let document = KeyboardTestDocument(text: "Keep old suffix")
    document.view.selectedRange = NSRange(location: 5, length: 3)
    let result = KeyboardSessionSnapshot(id: UUID(), phase: .ready, updatedAt: .now, text: "new")
    delivery.prepareAutomaticInsertion(for: result.id, in: document.context)

    XCTAssertFalse(delivery.insert(result, into: document, automatically: true))
    XCTAssertEqual(document.view.text, "Keep old suffix")
    XCTAssertTrue(delivery.insert(result, into: document))
    XCTAssertEqual(document.view.text, "Keep new suffix")
    XCTAssertFalse(delivery.undo(in: document))
    XCTAssertEqual(document.view.text, "Keep new suffix")
  }

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

@MainActor
private final class KeyboardTestDocument: KeyboardTextDocument {
  let view = UITextView()
  var identifier = UUID()
  var exposesContext = true

  init(text: String) {
    view.text = text
    view.selectedRange = NSRange(location: (text as NSString).length, length: 0)
  }

  var context: KeyboardTextContext {
    let text = view.text! as NSString
    let range = view.selectedRange
    return KeyboardTextContext(
      documentID: identifier,
      before: exposesContext ? text.substring(to: range.location) : nil,
      after: exposesContext ? text.substring(from: NSMaxRange(range)) : nil,
      selected: range.length == 0 ? nil : text.substring(with: range), hasText: view.hasText
    )
  }

  func insertText(_ text: String) { view.insertText(text) }
  func deleteBackward() { view.deleteBackward() }
}
