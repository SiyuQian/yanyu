enum DictationState: Equatable, Sendable {
  case ready
  case requestingPermission
  case recording
  case transcribing
  case transcript(String)
  case failed(String)
}

enum DictationEvent: Sendable {
  case requestPermission
  case permissionGranted
  case startRecording
  case stopRecording
  case retryTranscription
  case interrupted(String)
  case transcriptionCompleted(String)
  case failed(String)
  case reset
}

enum DictationStateMachine {
  static let initialState = DictationState.ready

  static func reduce(_ state: DictationState, event: DictationEvent) -> DictationState {
    switch event {
    case .requestPermission:
      switch state {
      case .ready, .transcript, .failed:
        return .requestingPermission
      case .requestingPermission, .recording, .transcribing:
        return state
      }
    case .permissionGranted:
      return state == .requestingPermission ? .recording : state
    case .startRecording:
      switch state {
      case .ready, .transcript, .failed:
        return .recording
      case .requestingPermission, .recording, .transcribing:
        return state
      }
    case .stopRecording:
      return state == .recording ? .transcribing : state
    case .retryTranscription:
      switch state {
      case .ready, .transcript, .failed:
        return .transcribing
      case .requestingPermission, .recording, .transcribing:
        return state
      }
    case .interrupted(let message):
      return state == .recording ? .failed(message) : state
    case .transcriptionCompleted(let text):
      return state == .transcribing ? .transcript(text) : state
    case .failed(let message):
      switch state {
      case .requestingPermission, .recording, .transcribing:
        return .failed(message)
      case .ready, .transcript, .failed:
        return state
      }
    case .reset:
      return .ready
    }
  }
}
