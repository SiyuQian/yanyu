import AppIntents

/// An explicitly selected Shortcuts action that starts recording in the containing app.
struct StartKeyboardDictationIntent: AppIntent {
  static let title: LocalizedStringResource = "iosApp.shortcutStartTitle"
  static let description = IntentDescription("iosApp.shortcutStartDescription")
  static let openAppWhenRun = true

  @available(iOS 26.0, *)
  static var supportedModes: IntentModes { .foreground }

  @MainActor
  func perform() async throws -> some IntentResult {
    KeyboardDictationLaunchRequest.shared.request()
    return .result()
  }
}
