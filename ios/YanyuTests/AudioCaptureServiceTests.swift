import Darwin
import XCTest

@testable import Yanyu

final class AudioCaptureServiceTests: XCTestCase {
  func testOutOfSpaceErrorsAreClassifiedForUserRecovery() {
    let error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)

    XCTAssertEqual(AudioWriteFailure.classify(error), .insufficientStorage)
  }

  func testPosixOutOfSpaceErrorsAreClassifiedForUserRecovery() {
    let error = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))

    XCTAssertEqual(AudioWriteFailure.classify(error), .insufficientStorage)
  }

  func testOtherWriteErrorsRemainGeneric() {
    let error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError)

    XCTAssertEqual(AudioWriteFailure.classify(error), .other)
  }

  func testRecordingStopsRetryingWritesAfterTheFirstWriteFailure() {
    let writeErrors = AudioWriteErrors()

    XCTAssertTrue(writeErrors.shouldWrite())
    writeErrors.record(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError))

    XCTAssertFalse(writeErrors.shouldWrite())
    XCTAssertEqual(writeErrors.takeFailure(), .insufficientStorage)
    XCTAssertTrue(writeErrors.shouldWrite())
  }

  @MainActor
  func testStoppingWithoutAnActiveRecordingReportsAnError() {
    let service = AudioCaptureService()

    XCTAssertThrowsError(try service.stopRecording()) { error in
      XCTAssertEqual(error as? AudioCaptureError, .notRecording)
    }
  }
}
