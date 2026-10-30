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
