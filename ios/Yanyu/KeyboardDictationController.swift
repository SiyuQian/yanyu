import Observation
import SwiftData
import UIKit

@MainActor
protocol KeyboardDictationDriver: AnyObject {
  var state: DictationState { get }
  var hasPendingTranscriptSave: Bool { get }
  var errorKey: String? { get set }
  func startRecording() async
  func stopAndTranscribe(using context: ModelContext)
  func handleRecordingInterruption(messageKey: String)
  func handleAppBackground()
}

extension DictationViewModel: KeyboardDictationDriver {}

/// Coordinates one explicitly started dictation. It never reads the host app's text field.
@Observable
@MainActor
final class KeyboardDictationController {
  private let store: KeyboardSessionStore?
  private var sessionID: UUID?
  private var startedAt: Date?
  private var backgroundTask = UIBackgroundTaskIdentifier.invalid
  private(set) var isActive = false

  init(store: KeyboardSessionStore? = .shared()) {
    self.store = store
  }

  func start(viewModel: any KeyboardDictationDriver) async {
    guard !isActive, !viewModel.hasPendingTranscriptSave else { return }
    switch viewModel.state {
    case .ready, .transcript, .failed: break
    default: return
    }
    guard let store else {
      viewModel.errorKey = "iosApp.keyboardUnavailable"
      return
    }
    do {
      try store.clear()
    } catch {
      viewModel.errorKey = "iosApp.keyboardUnavailable"
      return
    }
    let id = UUID()
    sessionID = id
    isActive = true
    await viewModel.startRecording()
    guard sessionID == id else {
      viewModel.handleRecordingInterruption(messageKey: "iosApp.audioInterrupted")
      return
    }
    guard viewModel.state == .recording else {
      finish()
      return
    }
    startedAt = .now
    do {
      try store.write(.init(id: id, phase: .recording, updatedAt: .now))
    } catch {
      cancel(viewModel: viewModel)
      viewModel.errorKey = "iosApp.keyboardUnavailable"
    }
  }

  func refresh(
    viewModel: any KeyboardDictationDriver, using context: ModelContext, now: Date = .now
  ) {
    guard let store else { return }
    guard let id = sessionID else {
      // iOS may suspend us after completing a result; purge it on the next app activation.
      do {
        if try store.read(now: now) == nil { try store.clear() }
      } catch {
        viewModel.errorKey = "iosApp.keyboardUnavailable"
      }
      return
    }
    do {
      if viewModel.state == .recording,
        try store.stopRequested(for: id) || now.timeIntervalSince(startedAt ?? now) >= 60
      {
        prepareForTranscription(viewModel: viewModel)
        viewModel.stopAndTranscribe(using: context)
      }
      let snapshot: KeyboardSessionSnapshot
      switch viewModel.state {
      case .requestingPermission:
        return
      case .recording:
        snapshot = .init(id: id, phase: .recording, updatedAt: now)
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
      if snapshot.phase == .ready || snapshot.phase == .failed { finish() }
    } catch {
      cancel(viewModel: viewModel)
      viewModel.errorKey = "iosApp.keyboardUnavailable"
    }
  }

  /// Call before stopping capture so the app has execution time after audio deactivation.
  func prepareForTranscription(viewModel: any KeyboardDictationDriver) {
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
    startedAt = nil
    isActive = false
    if backgroundTask != .invalid {
      UIApplication.shared.endBackgroundTask(backgroundTask)
      backgroundTask = .invalid
    }
  }
}
