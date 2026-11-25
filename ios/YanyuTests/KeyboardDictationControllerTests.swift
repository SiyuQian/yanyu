import SwiftData
import XCTest

@testable import Yanyu

final class KeyboardDictationControllerTests: XCTestCase {
  @MainActor
  func testKeyboardCanStartConfirmAndStartAgainAfterInsertion() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = KeyboardSessionStore(directory: directory)
    let controller = KeyboardDictationController(
      store: store, requestMicrophonePermission: { true })
    let driver = KeyboardTestDriver()
    let container = try makeContainer()
    await controller.enableMicrophone(viewModel: driver)
    let standby = try XCTUnwrap(store.read())
    XCTAssertEqual(standby.phase, .standby)
    XCTAssertEqual(driver.state, .ready)

    try store.requestStart(for: standby.id)
    controller.refresh(viewModel: driver, using: container.mainContext)
    XCTAssertEqual(driver.state, .recording)
    XCTAssertEqual(try store.read()?.id, standby.id)
    XCTAssertEqual(try store.read()?.startedFromKeyboard, true)

    try store.requestStop(for: standby.id)
    controller.refresh(viewModel: driver, using: container.mainContext)
    XCTAssertEqual(driver.state, .transcribing)
    driver.state = .transcript("你好")
    controller.refresh(viewModel: driver, using: container.mainContext)
    XCTAssertEqual(try store.read()?.text, "你好")
    controller.refresh(viewModel: driver, using: container.mainContext)
    XCTAssertEqual(try store.read()?.phase, .ready)

    try store.markResultHandled(for: standby.id)
    controller.refresh(viewModel: driver, using: container.mainContext)
    let next = try XCTUnwrap(store.read())
    XCTAssertEqual(next.phase, .standby)
    XCTAssertNotEqual(next.id, standby.id)
    try store.requestStart(for: next.id)
    controller.refresh(viewModel: driver, using: container.mainContext)
    XCTAssertEqual(driver.state, .recording)
    XCTAssertEqual(try store.read()?.id, next.id)
  }

  @MainActor
  func testCancelWhileStartingOrListeningReturnsToTypingWithoutAResult() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = KeyboardSessionStore(directory: directory)
    let controller = KeyboardDictationController(
      store: store, requestMicrophonePermission: { true })
    let driver = KeyboardTestDriver()
    let container = try makeContainer()
    await controller.enableMicrophone(viewModel: driver)
    let first = try XCTUnwrap(store.read())

    try store.requestStart(for: first.id)
    try store.requestCancel(for: first.id)
    controller.refresh(viewModel: driver, using: container.mainContext)
    XCTAssertEqual(driver.recordingStarts, 0)
    let next = try XCTUnwrap(store.read())
    XCTAssertEqual(next.phase, .standby)
    XCTAssertNotEqual(next.id, first.id)

    try store.requestStart(for: next.id)
    controller.refresh(viewModel: driver, using: container.mainContext)
    XCTAssertEqual(driver.recordingStarts, 1)
    try store.requestStop(for: next.id)
    try store.requestCancel(for: next.id)
    controller.refresh(viewModel: driver, using: container.mainContext)
    XCTAssertEqual(driver.state, .ready)
    XCTAssertFalse(controller.isActive)
    XCTAssertEqual(try store.read()?.phase, .standby)
    XCTAssertNil(controller.pendingResult)
  }

  @MainActor
  func testStandbyExpiresAndDisablesInputEvenWhenAStartWasRequested() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = KeyboardSessionStore(directory: directory)
    var elapsed = ContinuousClock.now
    let controller = KeyboardDictationController(
      store: store, requestMicrophonePermission: { true }, elapsedNow: { elapsed })
    let driver = KeyboardTestDriver()
    let container = try makeContainer()
    await controller.enableMicrophone(viewModel: driver)
    let standby = try XCTUnwrap(store.read())
    try store.requestStart(for: standby.id)

    elapsed = elapsed.advanced(by: .seconds(301))
    let afterExpiry = standby.updatedAt.addingTimeInterval(-30)
    controller.refresh(viewModel: driver, using: container.mainContext, now: afterExpiry)
    XCTAssertFalse(driver.isKeyboardMicrophoneRunning)
    XCTAssertEqual(driver.recordingStarts, 0)
    XCTAssertNil(try store.read(now: afterExpiry))
  }

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
    driver.onStop = {
      XCTAssertEqual(try? store.read()?.phase, .transcribing)
      do {
        try store.requestCancel(for: session.id)
        XCTFail("The recording must stop accepting cancels before transcription starts")
      } catch CocoaError.fileReadNoSuchFile {
      } catch {
        XCTFail("Unexpected cancellation error: \(error)")
      }
    }
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
    var elapsed = ContinuousClock.now
    let controller = KeyboardDictationController(
      store: .init(directory: directory), elapsedNow: { elapsed })
    let driver = KeyboardTestDriver()
    let container = try makeContainer()
    await controller.start(viewModel: driver)
    elapsed = elapsed.advanced(by: .seconds(61))
    controller.refresh(viewModel: driver, using: container.mainContext)
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
  var canStartKeyboardRecording = true
  var isKeyboardMicrophoneRunning = false
  var recordingStarts = 0
  var onStop: (() -> Void)?
  var keyboardMicrophoneName: String? { "Test Microphone" }
  var keyboardAudioLevel: Float { 0 }
  func enableKeyboardMicrophone() throws { isKeyboardMicrophoneRunning = true }
  func disableKeyboardMicrophone() { isKeyboardMicrophoneRunning = false }
  func startKeyboardRecording() {
    recordingStarts += 1
    state = .recording
  }
  func discardPendingAudio() { state = .ready }
  func startRecording() async { state = .recording }
  func stopAndTranscribe(using context: ModelContext) {
    onStop?()
    state = .transcribing
  }
  func handleRecordingInterruption(messageKey: String) { state = .failed(messageKey) }
  func handleAppBackground() { state = .failed("iosApp.backgroundTranscriptionStopped") }
}
