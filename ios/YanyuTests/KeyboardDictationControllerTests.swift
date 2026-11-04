import SwiftData
import XCTest

@testable import Yanyu

final class KeyboardDictationControllerTests: XCTestCase {
  @MainActor
  func testKeyboardStopTranscribesAndPublishesOnlySavedResult() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = KeyboardSessionStore(directory: directory)
    let controller = KeyboardDictationController(store: store)
    let driver = KeyboardTestDriver()
    let container = try makeContainer()
    await controller.start(viewModel: driver)
    XCTAssertTrue(controller.isActive)
    let session = try XCTUnwrap(store.read())
    XCTAssertEqual(session.phase, .recording)
    try store.requestStop(for: session.id)
    controller.refresh(viewModel: driver, using: container.mainContext)
    XCTAssertEqual(driver.state, .transcribing)
    XCTAssertEqual(try store.read()?.phase, .transcribing)
    driver.state = .transcript("你好")
    driver.hasPendingTranscriptSave = true
    controller.refresh(viewModel: driver, using: container.mainContext)
    XCTAssertEqual(try store.read()?.phase, .failed)
    XCTAssertNil(try store.read()?.text)
    XCTAssertFalse(controller.isActive)
  }

  @MainActor
  func testCompletedSessionPublishesResultWithoutSharingOtherHistory() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = KeyboardSessionStore(directory: directory)
    let controller = KeyboardDictationController(store: store)
    let driver = KeyboardTestDriver()
    let container = try makeContainer()
    await controller.start(viewModel: driver)
    driver.state = .transcript("Hello 世界")
    controller.refresh(viewModel: driver, using: container.mainContext)
    XCTAssertEqual(try store.read()?.text, "Hello 世界")
    XCTAssertEqual(try store.read()?.phase, .ready)
    XCTAssertFalse(controller.isActive)
    XCTAssertEqual(controller.pendingResult?.text, "Hello 世界")
    driver.state = .transcript("Private history")
    controller.refresh(viewModel: driver, using: container.mainContext)
    XCTAssertEqual(try store.read()?.text, "Hello 世界")
  }

  @MainActor
  func testRecordingLimitStopsAndTranscribesInsteadOfRecordingIndefinitely() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let controller = KeyboardDictationController(store: .init(directory: directory))
    let driver = KeyboardTestDriver()
    let container = try makeContainer()
    await controller.start(viewModel: driver)
    controller.refresh(
      viewModel: driver, using: container.mainContext, now: .now.addingTimeInterval(61))
    XCTAssertEqual(driver.state, .transcribing)
    controller.cancel(viewModel: driver)
    XCTAssertFalse(controller.isActive)
    XCTAssertEqual(driver.state, .failed("iosApp.backgroundTranscriptionStopped"))
  }

  @MainActor
  func testUnavailableSharedContainerDoesNotStartMicrophone() async {
    let driver = KeyboardTestDriver()
    let controller = KeyboardDictationController(store: nil)
    await controller.start(viewModel: driver)
    XCTAssertEqual(driver.state, .ready)
    XCTAssertEqual(driver.errorKey, "iosApp.keyboardUnavailable")
    XCTAssertFalse(controller.isActive)
  }

  @MainActor
  func testUnhandledReadyResultBlocksNewRecordingWithoutReplacingSharedText() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = KeyboardSessionStore(directory: directory)
    let result = KeyboardSessionSnapshot(
      id: UUID(), phase: .ready, updatedAt: .now, text: "Keep this result")
    try store.write(result)
    let driver = KeyboardTestDriver()
    let controller = KeyboardDictationController(store: store)

    await controller.start(viewModel: driver)

    XCTAssertEqual(driver.state, .ready)
    XCTAssertFalse(controller.isActive)
    XCTAssertEqual(driver.errorKey, "iosApp.keyboardPendingResult")
    XCTAssertEqual(controller.pendingResult, result)
    XCTAssertEqual(try store.read(), result)
  }

  @MainActor
  func testHandledResultAllowsNewRecordingAndClearsItsReceipt() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = KeyboardSessionStore(directory: directory)
    let keyboard = KeyboardSessionStore(directory: directory)
    let result = KeyboardSessionSnapshot(
      id: UUID(), phase: .ready, updatedAt: .now, text: "Handled")
    try store.write(result)
    try keyboard.markResultHandled(for: result.id)
    let driver = KeyboardTestDriver()
    let controller = KeyboardDictationController(store: store)

    await controller.start(viewModel: driver)

    XCTAssertEqual(driver.state, .recording)
    XCTAssertTrue(controller.isActive)
    XCTAssertNil(controller.pendingResult)
    let recording = try XCTUnwrap(store.read())
    XCTAssertEqual(recording.phase, .recording)
    XCTAssertNotEqual(recording.id, result.id)
    XCTAssertFalse(try store.isResultHandled(for: result.id))
    controller.cancel(viewModel: driver)
  }

  @MainActor
  func testReceiptForOlderResultDoesNotAllowReplacingANewerResult() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = KeyboardSessionStore(directory: directory)
    let keyboard = KeyboardSessionStore(directory: directory)
    let first = KeyboardSessionSnapshot(id: UUID(), phase: .ready, updatedAt: .now, text: "First")
    try store.write(first)
    try keyboard.markResultHandled(for: first.id)
    let second = KeyboardSessionSnapshot(id: UUID(), phase: .ready, updatedAt: .now, text: "Second")
    try store.write(second)
    let driver = KeyboardTestDriver()
    let controller = KeyboardDictationController(store: store)

    await controller.start(viewModel: driver)

    XCTAssertEqual(driver.state, .ready)
    XCTAssertEqual(controller.pendingResult, second)
    XCTAssertEqual(try store.read(), second)
  }

  @MainActor
  func testIdleRefreshFindsPendingResultAndHidesHandledOrExpiredHandoff() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = KeyboardSessionStore(directory: directory)
    let keyboard = KeyboardSessionStore(directory: directory)
    let result = KeyboardSessionSnapshot(id: UUID(), phase: .ready, updatedAt: .now, text: "Ready")
    try store.write(result)
    let driver = KeyboardTestDriver()
    driver.errorKey = "iosApp.keyboardPendingResult"
    let controller = KeyboardDictationController(store: store)
    let container = try makeContainer()
    controller.refresh(viewModel: driver, using: container.mainContext)
    XCTAssertEqual(controller.pendingResult, result)
    XCTAssertEqual(driver.errorKey, "iosApp.keyboardPendingResult")

    try keyboard.markResultHandled(for: result.id)
    controller.refresh(viewModel: driver, using: container.mainContext)
    XCTAssertNil(controller.pendingResult)
    XCTAssertNil(driver.errorKey)
    XCTAssertEqual(try store.read(), result)
    driver.errorKey = "iosApp.genericError"
    controller.refresh(
      viewModel: driver, using: container.mainContext, now: result.updatedAt.addingTimeInterval(301)
    )
    XCTAssertNil(controller.pendingResult)
    XCTAssertNil(try store.read(now: result.updatedAt.addingTimeInterval(301)))
    XCTAssertFalse(try keyboard.isResultHandled(for: result.id))
    XCTAssertEqual(driver.errorKey, "iosApp.genericError")
  }

  @MainActor
  func testDismissPendingResultRequiresCurrentIDAndPreservesSavedHistory() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = KeyboardSessionStore(directory: directory)
    let result = KeyboardSessionSnapshot(
      id: UUID(), phase: .ready, updatedAt: .now, text: "Saved text")
    try store.write(result)
    let driver = KeyboardTestDriver()
    let controller = KeyboardDictationController(store: store)
    let container = try makeContainer()
    container.mainContext.insert(TranscriptRecord(text: "Saved text"))
    try container.mainContext.save()
    controller.refresh(viewModel: driver, using: container.mainContext)

    XCTAssertFalse(controller.dismissPendingResult(id: UUID()))
    XCTAssertEqual(try store.read(), result)
    XCTAssertTrue(controller.dismissPendingResult(id: result.id))
    XCTAssertNil(controller.pendingResult)
    XCTAssertNil(try store.read())
    XCTAssertEqual(
      try container.mainContext.fetch(FetchDescriptor<TranscriptRecord>()).map(\.text),
      ["Saved text"])
  }

  @MainActor
  func testStaleDismissalNeverClearsNewerResult() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = KeyboardSessionStore(directory: directory)
    let first = KeyboardSessionSnapshot(id: UUID(), phase: .ready, updatedAt: .now, text: "First")
    try store.write(first)
    let driver = KeyboardTestDriver()
    let controller = KeyboardDictationController(store: store)
    let container = try makeContainer()
    controller.refresh(viewModel: driver, using: container.mainContext)
    let second = KeyboardSessionSnapshot(id: UUID(), phase: .ready, updatedAt: .now, text: "Newer")
    try store.write(second)

    XCTAssertFalse(controller.dismissPendingResult(id: first.id))
    XCTAssertEqual(try store.read(), second)
    controller.refresh(viewModel: driver, using: container.mainContext)
    XCTAssertEqual(controller.pendingResult, second)
  }

  @MainActor
  func testDismissalCannotClearAnActiveSession() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = KeyboardSessionStore(directory: directory)
    let controller = KeyboardDictationController(store: store)
    let driver = KeyboardTestDriver()
    await controller.start(viewModel: driver)
    let session = try XCTUnwrap(store.read())
    let ready = KeyboardSessionSnapshot(
      id: session.id, phase: .ready, updatedAt: .now, text: "Late ready")
    try store.write(ready)

    XCTAssertFalse(controller.dismissPendingResult(id: session.id))
    XCTAssertTrue(controller.isActive)
    XCTAssertEqual(try store.read(), ready)
    controller.cancel(viewModel: driver)
  }

  @MainActor
  func testCorruptReceiptBlocksNewRecordingAndPreservesResult() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = KeyboardSessionStore(directory: directory)
    let result = KeyboardSessionSnapshot(
      id: UUID(), phase: .ready, updatedAt: .now, text: "Keep me")
    try store.write(result)
    try Data("invalid".utf8).write(to: directory.appendingPathComponent("handled.json"))
    let driver = KeyboardTestDriver()
    let controller = KeyboardDictationController(store: store)

    await controller.start(viewModel: driver)

    XCTAssertEqual(driver.state, .ready)
    XCTAssertFalse(controller.isActive)
    XCTAssertEqual(driver.errorKey, "iosApp.keyboardUnavailable")
    XCTAssertEqual(controller.pendingResult, result)
    XCTAssertEqual(try store.read(), result)
    XCTAssertTrue(controller.dismissPendingResult(id: result.id))
    XCTAssertNil(try store.read())
  }

  @MainActor
  func testCorruptSnapshotBlocksNewRecordingWithoutClearingSharedData() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let snapshotURL = directory.appendingPathComponent("session.json")
    let invalidData = Data("invalid".utf8)
    try invalidData.write(to: snapshotURL)
    let driver = KeyboardTestDriver()
    let controller = KeyboardDictationController(store: .init(directory: directory))

    await controller.start(viewModel: driver)

    XCTAssertEqual(driver.state, .ready)
    XCTAssertFalse(controller.isActive)
    XCTAssertEqual(driver.errorKey, "iosApp.keyboardUnavailable")
    XCTAssertEqual(try Data(contentsOf: snapshotURL), invalidData)
  }

  @MainActor
  private func makeContainer() throws -> ModelContainer {
    try ModelContainer(
      for: TranscriptRecord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
  }
}

@MainActor
private final class KeyboardTestDriver: KeyboardDictationDriver {
  var state = DictationState.ready
  var hasPendingTranscriptSave = false
  var errorKey: String?
  func startRecording() async { state = .recording }
  func stopAndTranscribe(using context: ModelContext) { state = .transcribing }
  func handleRecordingInterruption(messageKey: String) { state = .failed(messageKey) }
  func handleAppBackground() { state = .failed("iosApp.backgroundTranscriptionStopped") }
}
