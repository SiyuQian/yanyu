import AVFAudio
import Darwin
import Foundation

enum AudioCaptureError: Error, Equatable {
  case alreadyRecording
  case notRecording
  case microphonePermissionDenied
  case inputUnavailable
  case captureFailed(String)
}

enum AudioCaptureWarning: Equatable, Sendable {
  case recordingMayBeIncomplete
  case insufficientStorage
}

enum AudioWriteFailure: Equatable {
  case insufficientStorage
  case other

  static func classify(_ error: Error) -> Self {
    let nsError = error as NSError
    let cocoaOutOfSpace =
      nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError
    let posixOutOfSpace = nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOSPC)
    if cocoaOutOfSpace || posixOutOfSpace {
      return .insufficientStorage
    }
    return .other
  }
}

struct AudioCaptureResult: Sendable {
  let audioFile: TemporaryAudioFile
  let warning: AudioCaptureWarning?
}

@MainActor
final class AudioCaptureService {
  private let engine = AVAudioEngine()
  private let writeErrors = AudioWriteErrors()
  private var currentFile: TemporaryAudioFile?
  private var outputFile: AVAudioFile?

  var isRecording: Bool {
    currentFile != nil
  }

  func startRecording() async throws {
    guard !isRecording else {
      throw AudioCaptureError.alreadyRecording
    }
    guard await AVAudioApplication.requestRecordPermission() else {
      throw AudioCaptureError.microphonePermissionDenied
    }

    let session = AVAudioSession.sharedInstance()
    let file = try TemporaryAudioFile()
    let input = engine.inputNode
    var tapInstalled = false

    do {
      try session.setCategory(.record, mode: .measurement)
      try session.setActive(true)

      let format = input.outputFormat(forBus: 0)
      guard format.channelCount > 0, format.sampleRate > 0 else {
        throw AudioCaptureError.inputUnavailable
      }

      let outputFile = try AVAudioFile(
        forWriting: file.url,
        settings: format.settings,
        commonFormat: .pcmFormatFloat32,
        interleaved: false
      )
      writeErrors.reset()
      let writeErrors = writeErrors
      input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
        guard writeErrors.shouldWrite() else {
          return
        }
        do {
          try outputFile.write(from: buffer)
        } catch {
          writeErrors.record(error)
        }
      }
      tapInstalled = true
      engine.prepare()
      try engine.start()

      currentFile = file
      self.outputFile = outputFile
    } catch {
      if tapInstalled {
        input.removeTap(onBus: 0)
      }
      engine.stop()
      try? session.setActive(false, options: .notifyOthersOnDeactivation)
      try? file.remove()
      if let captureError = error as? AudioCaptureError {
        throw captureError
      }
      throw AudioCaptureError.captureFailed(error.localizedDescription)
    }
  }

  func stopRecording() throws -> AudioCaptureResult {
    guard let file = currentFile else {
      throw AudioCaptureError.notRecording
    }

    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    outputFile = nil
    currentFile = nil

    var warning: AudioCaptureWarning?
    do {
      try AVAudioSession.sharedInstance().setActive(
        false,
        options: .notifyOthersOnDeactivation
      )
    } catch {
      warning = .recordingMayBeIncomplete
    }

    if let failure = writeErrors.takeFailure() {
      warning =
        switch failure {
        case .insufficientStorage:
          .insufficientStorage
        case .other:
          .recordingMayBeIncomplete
        }
    }
    return AudioCaptureResult(audioFile: file, warning: warning)
  }

  func cancelRecording() throws {
    let result = try stopRecording()
    try result.audioFile.remove()
  }
}

final class AudioWriteErrors: @unchecked Sendable {
  private let lock = NSLock()
  private var failure: AudioWriteFailure?

  func reset() {
    lock.lock()
    defer { lock.unlock() }
    failure = nil
  }

  func shouldWrite() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return failure == nil
  }

  func record(_ error: Error) {
    lock.lock()
    defer { lock.unlock() }
    if failure == nil {
      failure = AudioWriteFailure.classify(error)
    }
  }

  func takeFailure() -> AudioWriteFailure? {
    lock.lock()
    defer { lock.unlock() }
    defer { failure = nil }
    return failure
  }
}
