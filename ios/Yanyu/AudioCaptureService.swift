import AVFAudio
import Accelerate
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
  private let writer = AudioCaptureWriter()
  private var inputFormat: AVAudioFormat?
  private var currentFile: TemporaryAudioFile?
  private var keepsKeyboardMicrophoneOpen = false

  var isRecording: Bool {
    currentFile != nil
  }

  var isKeyboardMicrophoneRunning: Bool {
    keepsKeyboardMicrophoneOpen && engine.isRunning
  }

  var microphoneName: String? {
    AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName
  }

  var audioLevel: Float { writer.takeLevel() }

  func startRecording() async throws {
    guard !isRecording else {
      throw AudioCaptureError.alreadyRecording
    }
    guard await AVAudioApplication.requestRecordPermission() else {
      throw AudioCaptureError.microphonePermissionDenied
    }
    try startInput(forKeyboard: false)
    do {
      try startWriting()
    } catch {
      try? stopInput()
      throw error
    }
  }

  func enableKeyboardMicrophone() throws {
    try startInput(forKeyboard: true)
    keepsKeyboardMicrophoneOpen = true
  }

  func disableKeyboardMicrophone() {
    keepsKeyboardMicrophoneOpen = false
    if !isRecording { try? stopInput() }
  }

  func startKeyboardRecording() throws {
    guard isKeyboardMicrophoneRunning else { throw AudioCaptureError.inputUnavailable }
    try startWriting()
  }

  func stopRecording() throws -> AudioCaptureResult {
    guard let file = currentFile else {
      throw AudioCaptureError.notRecording
    }

    let failure = writer.finish()
    currentFile = nil

    var warning: AudioCaptureWarning?
    if !keepsKeyboardMicrophoneOpen {
      do {
        try stopInput()
      } catch {
        warning = .recordingMayBeIncomplete
      }
    }

    if let failure {
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

  private func startInput(forKeyboard: Bool) throws {
    guard inputFormat == nil else { throw AudioCaptureError.alreadyRecording }
    let session = AVAudioSession.sharedInstance()
    do {
      if forKeyboard {
        try session.setCategory(
          .playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker])
      } else {
        try session.setCategory(.record, mode: .measurement)
      }
      try session.setActive(true)

      let input = engine.inputNode
      let format = input.outputFormat(forBus: 0)
      guard format.channelCount > 0, format.sampleRate > 0 else {
        throw AudioCaptureError.inputUnavailable
      }
      let writer = writer
      input.installTap(onBus: 0, bufferSize: 1_024, format: format) { @Sendable buffer, time in
        writer.write(buffer, at: time)
      }
      inputFormat = format
      engine.prepare()
      try engine.start()
    } catch {
      if inputFormat != nil {
        try? stopInput()
      } else {
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
      }
      if let captureError = error as? AudioCaptureError { throw captureError }
      throw AudioCaptureError.captureFailed(error.localizedDescription)
    }
  }

  private func startWriting() throws {
    guard !isRecording else { throw AudioCaptureError.alreadyRecording }
    guard let inputFormat else { throw AudioCaptureError.inputUnavailable }
    let file = try TemporaryAudioFile()
    do {
      let output = try AVAudioFile(
        forWriting: file.url, settings: inputFormat.settings, commonFormat: .pcmFormatFloat32,
        interleaved: false)
      writer.begin(output)
      currentFile = file
    } catch {
      try? file.remove()
      throw AudioCaptureError.captureFailed(error.localizedDescription)
    }
  }

  private func stopInput() throws {
    guard inputFormat != nil else { return }
    inputFormat = nil
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }
}

/// A live input tap has no output file until the user starts dictating.
final class AudioCaptureWriter: @unchecked Sendable {
  private let lock = NSLock()
  private var file: AVAudioFile?
  private var startedAt: UInt64 = 0
  private var failure: AudioWriteFailure?
  private var peak: Float = 0

  func begin(_ file: AVAudioFile) {
    lock.withLock {
      self.file = file
      startedAt = mach_absolute_time()
      failure = nil
      peak = 0
    }
  }

  func write(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
    lock.withLock {
      guard let file, failure == nil, !time.isHostTimeValid || time.hostTime >= startedAt else {
        return
      }
      do {
        try file.write(from: buffer)
      } catch {
        failure = AudioWriteFailure.classify(error)
        return
      }
      if let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 {
        var level: Float = 0
        vDSP_maxmgv(channel, buffer.stride, &level, vDSP_Length(buffer.frameLength))
        peak = max(peak, level)
      }
    }
  }

  func takeLevel() -> Float {
    lock.withLock {
      defer { peak = 0 }
      return min(1, peak.squareRoot())
    }
  }

  func finish() -> AudioWriteFailure? {
    lock.withLock {
      file = nil
      defer { failure = nil }
      return failure
    }
  }
}
