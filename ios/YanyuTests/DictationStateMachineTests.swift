import XCTest

@testable import Yanyu

final class DictationStateMachineTests: XCTestCase {
  func testNewSessionIsReady() {
    XCTAssertEqual(DictationStateMachine.initialState, .ready)
  }

  func testStartingFromReadyBeginsRecording() {
    XCTAssertEqual(
      DictationStateMachine.reduce(.ready, event: .startRecording),
      .recording
    )
  }

  func testPermissionRequestWaitsBeforeRecordingStarts() {
    XCTAssertEqual(
      DictationStateMachine.reduce(.ready, event: .requestPermission),
      .requestingPermission
    )
    XCTAssertEqual(
      DictationStateMachine.reduce(.requestingPermission, event: .permissionGranted),
      .recording
    )
  }

  func testRepeatedPermissionRequestDoesNotStartAnotherRequest() {
    XCTAssertEqual(
      DictationStateMachine.reduce(.requestingPermission, event: .requestPermission),
      .requestingPermission
    )
  }

  func testPermissionFailureCanBeRetried() {
    let failedState = DictationStateMachine.reduce(
      .requestingPermission,
      event: .failed("iosApp.permissionDenied")
    )

    XCTAssertEqual(failedState, .failed("iosApp.permissionDenied"))
    XCTAssertEqual(
      DictationStateMachine.reduce(failedState, event: .requestPermission),
      .requestingPermission
    )
  }

  func testStoppingRecordingStartsTranscription() {
    XCTAssertEqual(
      DictationStateMachine.reduce(.recording, event: .stopRecording),
      .transcribing
    )
  }

  func testRecoveredAudioCanBeRetried() {
    XCTAssertEqual(
      DictationStateMachine.reduce(.failed("iosApp.genericError"), event: .retryTranscription),
      .transcribing
    )
  }

  func testInterruptionStopsAnActiveRecording() {
    XCTAssertEqual(
      DictationStateMachine.reduce(.recording, event: .interrupted("iosApp.audioInterrupted")),
      .failed("iosApp.audioInterrupted")
    )
  }

  func testBackgroundFailureStopsTranscriptionWithRecoverableState() {
    XCTAssertEqual(
      DictationStateMachine.reduce(
        .transcribing,
        event: .failed("iosApp.backgroundTranscriptionStopped")
      ),
      .failed("iosApp.backgroundTranscriptionStopped")
    )
  }

  func testCompletedTranscriptionKeepsEditableText() {
    XCTAssertEqual(
      DictationStateMachine.reduce(
        .transcribing,
        event: .transcriptionCompleted("hello world")
      ),
      .transcript("hello world")
    )
  }

  func testInvalidEventDoesNotDiscardCurrentState() {
    XCTAssertEqual(
      DictationStateMachine.reduce(.ready, event: .stopRecording),
      .ready
    )
  }

  func testStartingWhileTranscribingDoesNotStartAnotherRecording() {
    XCTAssertEqual(
      DictationStateMachine.reduce(.transcribing, event: .startRecording),
      .transcribing
    )
  }

  func testResetReturnsToReady() {
    XCTAssertEqual(
      DictationStateMachine.reduce(.transcript("hello"), event: .reset),
      .ready
    )
  }
}
