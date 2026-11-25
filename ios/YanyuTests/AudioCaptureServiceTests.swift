import AVFAudio
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

  func testAStandbyMicrophoneWritesOnlyBuffersFromAnActiveRecording() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
    buffer.frameLength = 160
    let writer = AudioCaptureWriter()
    let beforeStart = AVAudioTime(hostTime: mach_absolute_time())
    writer.write(buffer, at: beforeStart)
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

    writer.begin(try AVAudioFile(forWriting: url, settings: format.settings))
    writer.write(buffer, at: beforeStart)
    writer.write(buffer, at: AVAudioTime(hostTime: mach_absolute_time()))
    XCTAssertNil(writer.finish())

    writer.write(buffer, at: AVAudioTime(hostTime: mach_absolute_time()))
    XCTAssertEqual(try AVAudioFile(forReading: url).length, 160)
  }

  @MainActor
  func testStoppingWithoutAnActiveRecordingReportsAnError() {
    let service = AudioCaptureService()

    XCTAssertThrowsError(try service.stopRecording()) { error in
      XCTAssertEqual(error as? AudioCaptureError, .notRecording)
    }
  }
}
