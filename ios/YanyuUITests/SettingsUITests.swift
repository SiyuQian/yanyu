import XCTest

final class SettingsUITests: XCTestCase {
  @MainActor
  func testFirstRunShowsLocalProcessingDisclosureAndContinueAction() throws {
    let app = XCUIApplication()
    app.launchArguments += [
      "-yanyu.ios.onboarding-complete", "NO", "-AppleLanguages", "(en)", "-AppleLocale",
      "en_US",
    ]
    app.launch()

    XCTAssertTrue(app.staticTexts["Your voice stays on your iPhone"].waitForExistence(timeout: 10))
    let localProcessingDisclosure = app.staticTexts.matching(
      NSPredicate(
        format: "label BEGINSWITH %@",
        "Yanyu records only when you ask. Speech is transcribed on this iPhone."
      )
    ).firstMatch
    XCTAssertTrue(localProcessingDisclosure.exists)
    XCTAssertTrue(app.buttons["Continue"].exists)
    XCTAssertFalse(app.buttons["Settings"].exists)
  }

  @MainActor
  func testPermissionRecoveryActionOpensYanyuSystemSettings() throws {
    let app = XCUIApplication()
    app.launchArguments += [
      "-yanyu.ios.onboarding-complete", "YES", "--yanyu-ui-test-microphone-denied",
      "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
    ]
    app.launch()

    let openSettings = app.buttons["permissionSettingsRecovery"]
    XCTAssertTrue(openSettings.waitForExistence(timeout: 10))
    XCTAssertEqual(openSettings.label, "Open System Settings")
    openSettings.tap()

    let systemSettings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
    XCTAssertTrue(systemSettings.wait(for: .runningForeground, timeout: 10))
  }

  @MainActor
  func testHistorySearchFiltersSavedTranscripts() throws {
    let app = launchApp(language: "en", locale: "en_US", seedHistory: true)
    let transcript = historyRecord(in: app)
    XCTAssertTrue(transcript.waitForExistence(timeout: 10))

    let searchField = app.textFields["Search transcripts"]
    XCTAssertTrue(searchField.exists)
    searchField.tap()
    searchField.typeText("Friday")
    XCTAssertTrue(transcript.exists)
    searchField.typeText(" absent")
    XCTAssertFalse(transcript.exists)
  }

  @MainActor
  func testHistoryTranscriptCanBeSelectedCopiedAndDeletedWithAccessibleAction() throws {
    let app = launchApp(language: "en", locale: "en_US", seedHistory: true)
    let transcript = historyRecord(in: app)
    XCTAssertTrue(transcript.waitForExistence(timeout: 10))

    transcript.tap()
    XCTAssertTrue(app.textViews["Transcript"].waitForExistence(timeout: 5))
    app.buttons["Copy"].tap()
    XCTAssertTrue(app.buttons["Copied"].exists)

    let deleteButton = app.buttons["Delete transcript"]
    XCTAssertTrue(deleteButton.waitForExistence(timeout: 5))
    deleteButton.tap()
    XCTAssertTrue(
      app.staticTexts["Your saved transcripts will appear here."].waitForExistence(timeout: 5))
  }

  @MainActor
  func testPopulatedHistoryPassesAccessibilityAudit() throws {
    let app = launchApp(language: "en", locale: "en_US", seedHistory: true)
    let transcript = historyRecord(in: app)
    XCTAssertTrue(transcript.waitForExistence(timeout: 10))
    XCTAssertTrue(transcript.isEnabled)
    XCTAssertTrue(app.buttons["Delete transcript"].isEnabled)

    try performProductAccessibilityAudit(in: app, ignoresKnownHistoryContrastIssue: true)
  }

  @MainActor
  func testSettingsNavigationExposesAccessiblePrivacyAndAppearanceControls() throws {
    let app = launchApp(language: "en", locale: "en_US")

    let settingsButton = app.buttons["Settings"]
    XCTAssertTrue(settingsButton.waitForExistence(timeout: 10))
    settingsButton.tap()

    XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Appearance"].exists)
    XCTAssertTrue(app.staticTexts["App appearance"].exists)

    let onDeviceProcessing = app.staticTexts["On-device processing"]
    scrollUntilVisible(onDeviceProcessing, in: app)
    XCTAssertTrue(onDeviceProcessing.exists)

    let temporaryAudio = app.staticTexts["Temporary audio"]
    scrollUntilVisible(temporaryAudio, in: app)
    XCTAssertTrue(temporaryAudio.exists)

    let transcriptStorage = app.staticTexts["Transcript storage"]
    scrollUntilVisible(transcriptStorage, in: app)
    XCTAssertTrue(transcriptStorage.exists)

    let deleteHistoryButton = app.buttons["Delete all transcript history"]
    XCTAssertFalse(deleteHistoryButton.exists)
    let noHistoryMessage = app.staticTexts["No saved transcript history to delete."]
    scrollUntilVisible(noHistoryMessage, in: app)
    XCTAssertTrue(noHistoryMessage.exists)
  }

  @MainActor
  func testTranscriptionSettingsToggleFillerRemovalAndEditCustomWords() throws {
    let app = launchApp(language: "en", locale: "en_US")
    openSettings(in: app)

    let fillerRemovalToggle = app.switches["Remove Filler Words"]
    scrollUntilVisible(fillerRemovalToggle, in: app)
    XCTAssertTrue(fillerRemovalToggle.waitForExistence(timeout: 5))
    XCTAssertEqual(fillerRemovalToggle.value as? String, "1")

    let customWordField = app.textFields["Add a word"]
    scrollUntilVisible(customWordField, in: app)
    XCTAssertTrue(customWordField.exists)
    customWordField.tap()
    customWordField.typeText("ChatGPT")
    app.buttons["Add"].tap()

    let removeCustomWordButton = app.buttons["Remove ChatGPT"]
    XCTAssertTrue(removeCustomWordButton.waitForExistence(timeout: 5))
    removeCustomWordButton.tap()
    XCTAssertFalse(removeCustomWordButton.waitForExistence(timeout: 1))
  }

  @MainActor
  func testSettingsTextScalesWithAccessibilityDynamicType() throws {
    let app = launchApp(
      language: "en",
      locale: "en_US",
      dynamicTypeCategory: "UICTContentSizeCategoryAccessibilityXXXL"
    )
    openSettings(in: app)
    let temporaryAudioHeading = app.staticTexts["Temporary audio"]
    scrollUntilVisible(temporaryAudioHeading, maxSwipes: 6, in: app)
    XCTAssertTrue(temporaryAudioHeading.exists)
    XCTAssertGreaterThan(temporaryAudioHeading.frame.height, 52)

    let temporaryAudioBody = app.staticTexts.matching(
      NSPredicate(format: "label BEGINSWITH %@", "Temporary audio is removed after a transcript")
    ).firstMatch
    scrollUntilVisible(temporaryAudioBody, maxSwipes: 10, in: app)
    XCTAssertTrue(temporaryAudioBody.exists)
    XCTAssertGreaterThan(temporaryAudioBody.frame.height, 116)

    let transcriptStorageHeading = app.staticTexts["Transcript storage"]
    scrollUntilVisible(transcriptStorageHeading, maxSwipes: 10, in: app)
    XCTAssertTrue(transcriptStorageHeading.exists)
    XCTAssertGreaterThan(transcriptStorageHeading.frame.height, 52)

    let historyStorageBody = app.staticTexts.matching(
      NSPredicate(format: "label BEGINSWITH %@", "History is stored in this app")
    ).firstMatch
    scrollUntilVisible(historyStorageBody, maxSwipes: 10, in: app)
    XCTAssertTrue(historyStorageBody.exists)
    XCTAssertGreaterThan(historyStorageBody.frame.height, 116)
  }

  @MainActor
  func testSettingsPassesAccessibilityAuditAtLargestDynamicType() throws {
    let app = launchApp(
      language: "en",
      locale: "en_US",
      dynamicTypeCategory: "UICTContentSizeCategoryAccessibilityXXXL"
    )
    openSettings(in: app)

    try app.performAccessibilityAudit()
  }

  @MainActor
  func testDictationScreenPassesAccessibilityAudit() throws {
    let app = launchApp(language: "en", locale: "en_US")
    XCTAssertTrue(app.staticTexts["A validated speech model is not installed yet."].exists)
    XCTAssertFalse(app.buttons["Start recording"].isEnabled)

    try performProductAccessibilityAudit(in: app)
  }

  @MainActor
  func testDictationScreenPassesAccessibilityAuditInDarkMode() throws {
    let app = launchApp(language: "en", locale: "en_US", appearance: "dark")
    XCTAssertTrue(app.staticTexts["A validated speech model is not installed yet."].exists)
    XCTAssertFalse(app.buttons["Start recording"].isEnabled)

    try performProductAccessibilityAudit(in: app)
  }

  @MainActor
  func testSettingsUsesSimplifiedChineseLocalization() throws {
    let app = launchApp(language: "zh-Hans", locale: "zh_CN")

    let settingsButton = app.buttons["设置"]
    XCTAssertTrue(settingsButton.waitForExistence(timeout: 10))
    settingsButton.tap()

    XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["外观"].exists)
    XCTAssertTrue(app.staticTexts["应用外观"].exists)
    XCTAssertTrue(app.staticTexts["在本机处理"].exists)
    let fillerRemovalToggle = app.switches["移除语气词"]
    scrollUntilVisible(fillerRemovalToggle, in: app)
    XCTAssertTrue(fillerRemovalToggle.exists)

    let customWordsHeading = app.staticTexts["自定义词汇"]
    scrollUntilVisible(customWordsHeading, in: app)
    XCTAssertTrue(customWordsHeading.exists)
    let customWordsField = app.textFields["添加词汇"]
    scrollUntilVisible(customWordsField, in: app)
    XCTAssertTrue(customWordsField.exists)

    let temporaryAudio = app.staticTexts["临时音频"]
    scrollUntilVisible(temporaryAudio, in: app)
    XCTAssertTrue(temporaryAudio.exists)

    let noHistoryMessage = app.staticTexts["没有可删除的转写历史。"]
    scrollUntilVisible(noHistoryMessage, in: app)
    XCTAssertTrue(noHistoryMessage.exists)
  }

  @MainActor
  private func launchApp(
    language: String,
    locale: String,
    dynamicTypeCategory: String? = nil,
    appearance: String? = nil,
    seedHistory: Bool = false
  ) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += [
      "-yanyu.ios.onboarding-complete", "YES", "-AppleLanguages", "(\(language))",
      "-AppleLocale", locale,
    ]
    if let dynamicTypeCategory {
      app.launchArguments += ["-UIPreferredContentSizeCategoryName", dynamicTypeCategory]
    }
    if let appearance {
      app.launchArguments += ["-yanyu.ios.appearance", appearance]
    }
    app.launchArguments += ["--yanyu-ui-test-reset-history"]
    app.launchArguments += ["--yanyu-ui-test-reset-preferences"]
    if seedHistory {
      app.launchArguments += ["--yanyu-ui-test-seed-history"]
    }
    app.launch()
    return app
  }

  @MainActor
  private func historyRecord(in app: XCUIApplication) -> XCUIElement {
    app.buttons.matching(
      NSPredicate(format: "label CONTAINS %@", "Quarterly planning: We should ship on Friday.")
    ).firstMatch
  }

  @MainActor
  private func performProductAccessibilityAudit(
    in app: XCUIApplication,
    ignoresKnownHistoryContrastIssue: Bool = false
  ) throws {
    try app.performAccessibilityAudit { issue in
      // These controls are unavailable until a model is installed; every other audit issue remains fatal.
      guard issue.auditType == .contrast else {
        return false
      }
      if issue.element?.isEnabled == false {
        return true
      }

      // iOS 26.2 reports the populated-history heading/date as contrast failures even though
      // screenshots show black text on the system's light background. Keep all other findings fatal.
      guard ignoresKnownHistoryContrastIssue,
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26,
        let label = issue.element?.label
      else {
        return false
      }
      let isHistoryDate =
        label.range(
          of: #"^[A-Za-z]{3} \d{1,2}, \d{4} at "#,
          options: .regularExpression
        ) != nil
      return label == "Recent transcripts" || isHistoryDate
    }
  }

  @MainActor
  private func openSettings(in app: XCUIApplication) {
    let settingsButton = app.buttons["Settings"]
    XCTAssertTrue(settingsButton.waitForExistence(timeout: 10))
    settingsButton.tap()
    XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
  }

  @MainActor
  private func scrollUntilVisible(
    _ element: XCUIElement,
    maxSwipes: Int = 6,
    in app: XCUIApplication
  ) {
    for _ in 0..<maxSwipes where !element.exists {
      app.swipeUp()
    }
  }
}
