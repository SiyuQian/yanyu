import AVFAudio
import Observation
import SwiftData
import UIKit

@MainActor
protocol KeyboardDictationDriver: AnyObject {
  var state: DictationState { get }
  var hasPendingTranscriptSave: Bool { get }
  var errorKey: String? { get set }
  var canStartKeyboardRecording: Bool { get }
  var isKeyboardMicrophoneRunning: Bool { get }
  var keyboardMicrophoneName: String? { get }
  var keyboardAudioLevel: Float { get }
  func enableKeyboardMicrophone() throws
  func disableKeyboardMicrophone()
  func startKeyboardRecording()
  func discardPendingAudio()
  func startRecording() async
  func stopAndTranscribe(using context: ModelContext)
  func handleRecordingInterruption(messageKey: String)
  func handleAppBackground()
}

extension DictationViewModel: KeyboardDictationDriver {}

/// Coordinates keyboard microphone availability and one explicitly started dictation at a time.
@Observable
@MainActor
final class KeyboardDictationController {
  private static let microphoneIdleLimit = Duration.seconds(300)
  private static let recordingLimit = Duration.seconds(60)
  private let store: KeyboardSessionStore?
  private let requestMicrophonePermission: () async -> Bool
  private let elapsedNow: () -> ContinuousClock.Instant
  private var microphonePreparationID: UUID?
  private var microphoneDeadline: ContinuousClock.Instant?
  private var standbyID = UUID()
  private var sessionID: UUID?
  private var startedFromKeyboard = false
  private var recordingDeadline: ContinuousClock.Instant?
  private var backgroundTask = UIBackgroundTaskIdentifier.invalid
  var isActive: Bool { sessionID != nil }
  var isPreparingMicrophone: Bool { microphonePreparationID != nil }
  var isMicrophoneEnabled: Bool { microphoneDeadline != nil }
  private(set) var pendingResult: KeyboardSessionSnapshot?

  init(
    store: KeyboardSessionStore? = .shared(),
    requestMicrophonePermission: @escaping () async -> Bool = {
      await AVAudioApplication.requestRecordPermission()
    },
    elapsedNow: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }
  ) {
    self.store = store
    self.requestMicrophonePermission = requestMicrophonePermission
    self.elapsedNow = elapsedNow
  }

  func enableMicrophone(viewModel: any KeyboardDictationDriver) async {
    guard !isActive, !isPreparingMicrophone, !isMicrophoneEnabled,
      viewModel.canStartKeyboardRecording, let store = prepareSession(viewModel: viewModel)
    else { return }

    let preparationID = UUID()
    microphonePreparationID = preparationID
    defer {
      if microphonePreparationID == preparationID { microphonePreparationID = nil }
    }
    let granted = await requestMicrophonePermission()
    guard microphonePreparationID == preparationID, !Task.isCancelled,
      UIApplication.shared.applicationState != .background,
      viewModel.canStartKeyboardRecording
    else { return }
    guard granted else {
      viewModel.errorKey = "iosApp.permissionDenied"
      return
    }
    do {
      try viewModel.enableKeyboardMicrophone()
    } catch {
      viewModel.errorKey = "iosApp.genericError"
      return
    }
    let now = Date.now
    standbyID = UUID()
    microphoneDeadline = elapsedNow().advanced(by: Self.microphoneIdleLimit)
    do {
      try store.write(.init(id: standbyID, phase: .standby, updatedAt: now))
      viewModel.errorKey = nil
    } catch {
      disableMicrophone(viewModel: viewModel)
      viewModel.errorKey = "iosApp.keyboardUnavailable"
    }
  }

  func disableMicrophone(viewModel: any KeyboardDictationDriver) {
    microphonePreparationID = nil
    guard isMicrophoneEnabled else { return }
    microphoneDeadline = nil
    viewModel.disableKeyboardMicrophone()
    do {
      if try store?.read()?.phase == .standby { try store?.clear() }
    } catch {
      viewModel.errorKey = "iosApp.keyboardUnavailable"
    }
  }

  func start(viewModel: any KeyboardDictationDriver) async {
    guard !isActive, !isPreparingMicrophone, !viewModel.hasPendingTranscriptSave else { return }
    switch viewModel.state {
    case .ready, .transcript, .failed: break
    default: return
    }
    guard let store = prepareSession(viewModel: viewModel) else { return }
    disableMicrophone(viewModel: viewModel)
    let id = UUID()
    sessionID = id
    await viewModel.startRecording()
    guard sessionID == id else {
      viewModel.handleRecordingInterruption(messageKey: "iosApp.audioInterrupted")
      return
    }
    guard viewModel.state == .recording else {
      finish()
      return
    }
    recordingDeadline = elapsedNow().advanced(by: Self.recordingLimit)
    do {
      try store.write(recordingSnapshot(id: id, viewModel: viewModel, now: .now))
    } catch {
      cancel(viewModel: viewModel)
      viewModel.errorKey = "iosApp.keyboardUnavailable"
    }
  }

  private func prepareSession(viewModel: any KeyboardDictationDriver) -> KeyboardSessionStore? {
    guard let store else {
      viewModel.errorKey = "iosApp.keyboardUnavailable"
      return nil
    }
    pendingResult = nil
    do {
      let snapshot = try store.read()
      if let snapshot, snapshot.phase == .ready {
        pendingResult = snapshot
        guard try store.isResultHandled(for: snapshot.id) else {
          viewModel.errorKey = "iosApp.keyboardPendingResult"
          return nil
        }
        pendingResult = nil
      }
      try store.clear()
      return store
    } catch {
      viewModel.errorKey = "iosApp.keyboardUnavailable"
      return nil
    }
  }

  func refresh(
    viewModel: any KeyboardDictationDriver, using context: ModelContext, now: Date = .now
  ) {
    guard let store else { return }
    if let deadline = microphoneDeadline,
      elapsedNow() >= deadline || !viewModel.isKeyboardMicrophoneRunning
    {
      let inputStopped = !viewModel.isKeyboardMicrophoneRunning
      disableMicrophone(viewModel: viewModel)
      if inputStopped {
        viewModel.handleRecordingInterruption(messageKey: "iosApp.audioInterrupted")
      }
    }
    do {
      guard let id = sessionID else {
        try refreshIdle(store: store, viewModel: viewModel, now: now)
        return
      }
      if viewModel.state == .recording {
        let reachedLimit = recordingDeadline.map { elapsedNow() >= $0 } ?? false
        if try store.stopRequested(for: id) || reachedLimit {
          try finishCapture(id: id, store: store, viewModel: viewModel, using: context, now: now)
          return
        }
        if try store.cancelRequested(for: id) {
          try discardCapture(id: id, store: store, viewModel: viewModel, now: now)
          return
        }
      }
      let snapshot: KeyboardSessionSnapshot
      switch viewModel.state {
      case .requestingPermission:
        return
      case .recording:
        snapshot = recordingSnapshot(id: id, viewModel: viewModel, now: now)
      case .transcribing:
        prepareForTranscription(viewModel: viewModel)
        snapshot = .init(id: id, phase: .transcribing, updatedAt: now)
      case .transcript(let text)
      where !viewModel.hasPendingTranscriptSave && viewModel.errorKey == nil:
        snapshot = .init(id: id, phase: .ready, updatedAt: now, text: text)
      default:
        snapshot = .init(id: id, phase: .failed, updatedAt: now)
      }
      try store.write(snapshot)
      if snapshot.phase == .ready || snapshot.phase == .failed {
        pendingResult = snapshot.phase == .ready ? snapshot : nil
        if snapshot.phase == .ready {
          renewMicrophoneDeadline()
        } else {
          disableMicrophone(viewModel: viewModel)
        }
        finish()
      }
    } catch {
      cancel(viewModel: viewModel)
      disableMicrophone(viewModel: viewModel)
      viewModel.errorKey = "iosApp.keyboardUnavailable"
    }
  }

  private func refreshIdle(
    store: KeyboardSessionStore, viewModel: any KeyboardDictationDriver, now: Date
  ) throws {
    let snapshot = try store.read(now: now)
    if let snapshot, snapshot.phase == .ready, try !store.isResultHandled(for: snapshot.id) {
      pendingResult = snapshot
      return
    }
    pendingResult = nil
    if viewModel.errorKey == "iosApp.keyboardPendingResult" { viewModel.errorKey = nil }
    if snapshot == nil {
      try store.clear()
      if isMicrophoneEnabled { standbyID = UUID() }
    }
    guard isMicrophoneEnabled, viewModel.canStartKeyboardRecording else {
      if snapshot?.phase == .standby {
        standbyID = UUID()
        try store.clear()
      }
      return
    }
    if snapshot?.phase == .standby, snapshot?.id == standbyID,
      try store.startRequested(for: standbyID, now: now)
    {
      let id = standbyID
      standbyID = UUID()
      if try !store.cancelRequested(for: id) {
        viewModel.startKeyboardRecording()
        guard viewModel.state == .recording else {
          disableMicrophone(viewModel: viewModel)
          try store.write(.init(id: id, phase: .failed, updatedAt: now))
          return
        }
        sessionID = id
        startedFromKeyboard = true
        recordingDeadline = elapsedNow().advanced(by: Self.recordingLimit)
        renewMicrophoneDeadline()
        try store.write(recordingSnapshot(id: id, viewModel: viewModel, now: now))
        return
      }
    }
    try store.write(.init(id: standbyID, phase: .standby, updatedAt: now))
  }

  private func recordingSnapshot(
    id: UUID, viewModel: any KeyboardDictationDriver, now: Date
  ) -> KeyboardSessionSnapshot {
    .init(
      id: id, phase: .recording, updatedAt: now, startedFromKeyboard: startedFromKeyboard,
      microphoneName: viewModel.keyboardMicrophoneName, audioLevel: viewModel.keyboardAudioLevel)
  }

  private func renewMicrophoneDeadline() {
    guard isMicrophoneEnabled else { return }
    microphoneDeadline = elapsedNow().advanced(by: Self.microphoneIdleLimit)
  }

  func stop(viewModel: any KeyboardDictationDriver, using context: ModelContext) {
    guard let store, let id = sessionID, viewModel.state == .recording else { return }
    do {
      try finishCapture(id: id, store: store, viewModel: viewModel, using: context, now: .now)
    } catch {
      cancel(viewModel: viewModel)
      viewModel.errorKey = "iosApp.keyboardUnavailable"
    }
  }

  private func finishCapture(
    id: UUID, store: KeyboardSessionStore, viewModel: any KeyboardDictationDriver,
    using context: ModelContext, now: Date
  ) throws {
    // Close cancellation admission before checking for a concurrently submitted cancel.
    try store.write(.init(id: id, phase: .transcribing, updatedAt: now))
    if try store.cancelRequested(for: id) {
      try discardCapture(id: id, store: store, viewModel: viewModel, now: now)
      return
    }
    prepareForTranscription(viewModel: viewModel)
    viewModel.stopAndTranscribe(using: context)
  }

  private func discardCapture(
    id: UUID, store: KeyboardSessionStore, viewModel: any KeyboardDictationDriver, now: Date
  ) throws {
    viewModel.handleRecordingInterruption(messageKey: "iosApp.audioInterrupted")
    viewModel.discardPendingAudio()
    finish()
    try store.clear()
    if viewModel.state == .ready {
      renewMicrophoneDeadline()
      try refreshIdle(store: store, viewModel: viewModel, now: now)
    } else {
      disableMicrophone(viewModel: viewModel)
      try store.write(.init(id: id, phase: .failed, updatedAt: now))
    }
  }

  /// Clears only the current shared handoff, leaving saved transcript history untouched.
  func dismissPendingResult(id: UUID) -> Bool {
    guard !isActive, let store else { return false }
    do {
      guard let snapshot = try store.read(), snapshot.id == id, snapshot.phase == .ready else {
        return false
      }
      try store.clear()
      pendingResult = nil
      return true
    } catch {
      return false
    }
  }

  /// Call before stopping capture so the app has execution time after audio deactivation.
  private func prepareForTranscription(viewModel: any KeyboardDictationDriver) {
    guard isActive, backgroundTask == .invalid else { return }
    backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Keyboard dictation") {
      [weak self, weak viewModel] in
      Task { @MainActor in
        guard let self, let viewModel else { return }
        self.cancel(viewModel: viewModel)
      }
    }
  }

  func cancel(viewModel: any KeyboardDictationDriver) {
    guard isActive else { return }
    disableMicrophone(viewModel: viewModel)
    if let store, let id = sessionID {
      do {
        try store.write(.init(id: id, phase: .failed, updatedAt: .now))
      } catch {
        viewModel.errorKey = "iosApp.keyboardUnavailable"
      }
    }
    viewModel.handleRecordingInterruption(messageKey: "iosApp.audioInterrupted")
    viewModel.handleAppBackground()
    finish()
  }

  private func finish() {
    sessionID = nil
    recordingDeadline = nil
    startedFromKeyboard = false
    if backgroundTask != .invalid {
      UIApplication.shared.endBackgroundTask(backgroundTask)
      backgroundTask = .invalid
    }
  }
}
