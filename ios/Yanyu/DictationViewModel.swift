import Darwin
import Foundation
import Observation
import SwiftData

enum CustomWordPreferenceError: Error, Equatable {
  case invalid
  case tooLong
  case duplicate(word: String)
}

@Observable
@MainActor
final class DictationViewModel {
  private let audioCapture = AudioCaptureService()
  private let transcriptionEngine: any TranscriptionEngine
  private let modelPackageStore: ModelPackageStore?
  private let modelPackageDownloadTransport: any ModelPackageDownloadTransport
  private let recoverPendingAudio: () throws -> TemporaryAudioFile?
  private var transcriptionTask: Task<Void, Never>?
  private var editSaveTask: Task<Void, Never>?
  private var selectedRecord: TranscriptRecord?
  private var pendingAudioFile: TemporaryAudioFile?
  private var pendingAudioTranscriptRecordID: UUID?
  private var canRetryPendingTranscription = false
  private var canSavePartialTranscript = false
  private var pendingTranscriptRecord: TranscriptRecord?
  private var hasAttemptedLocalRestore = false
  private var languageSelection: ModelLanguageSelection
  @ObservationIgnored private let preferencesDefaults: UserDefaults

  private(set) var state = DictationStateMachine.initialState
  private(set) var transcript = ""
  private(set) var isModelLoaded = false
  private(set) var fillerWordRemovalEnabled: Bool
  private(set) var customWords: [String]
  private(set) var transcriptionProgress: TranscriptionProgress?
  private(set) var recordingStartedAt: Date?
  var errorKey: String?
  var noticeKey: String?
  #if DEBUG
    private(set) var evaluation: InferenceEvaluation?
    private(set) var isEvaluatingAudio = false
    var evaluationErrorKey: String?
    private(set) var isInstallingCatalogModel = false
    private(set) var isLoadingCatalogModel = false
    private(set) var catalogModelDownloadProgress: ModelPackageDownloadProgress?
    var catalogModelInstallErrorKey: String?
    private var catalogModelInstallTask: Task<InstalledModelPackage, Error>?
    private var catalogModelInstallID: UUID?
  #endif

  var hasPendingAudioRecovery: Bool {
    pendingAudioFile != nil && canRetryPendingTranscription && pendingTranscriptRecord == nil
  }

  var hasDiscardablePendingAudio: Bool {
    pendingAudioFile != nil && pendingTranscriptRecord == nil
  }

  var hasPendingTranscriptSave: Bool {
    pendingTranscriptRecord != nil
  }

  var hasPartialTranscriptToSave: Bool {
    canSavePartialTranscript
      && !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && pendingTranscriptRecord == nil
      && state != .transcribing
  }

  var hasTranscriptForDisplay: Bool {
    selectedRecord != nil || pendingTranscriptRecord != nil || !transcript.isEmpty
  }

  var shouldOfferSystemSettingsRecovery: Bool {
    errorKey == "iosApp.permissionDenied"
  }

  private let modelPathKey = "yanyu.ios.debug-model-path"
  private let modelNameKey = "yanyu.ios.debug-model-name"
  private let modelPackageIDKey = "yanyu.ios.debug-model-package-id"
  private let modelPackageVersionKey = "yanyu.ios.debug-model-package-version"
  private let pendingAudioSavedKey = "yanyu.ios.pending-audio-saved"
  private let pendingAudioFailureKey = "yanyu.ios.pending-audio-failure"
  private static let languageIntentKey = "yanyu.ios.language-intent"
  private static let fillerWordRemovalKey = "yanyu.ios.filler-word-removal-enabled"
  private static let customWordsKey = "yanyu.ios.custom-words"

  init(
    pendingAudioFile: TemporaryAudioFile? = nil,
    transcriptionEngine: any TranscriptionEngine = YanyuCoreService(),
    modelPackageStore: ModelPackageStore? = nil,
    modelPackageDownloadTransport: any ModelPackageDownloadTransport =
      URLSessionModelPackageDownloadTransport(),
    recoverPendingAudio: @escaping () throws -> TemporaryAudioFile? = {
      try TemporaryAudioFile.recoverPending()
    },
    userDefaults: UserDefaults = .standard
  ) {
    self.pendingAudioFile = pendingAudioFile
    self.transcriptionEngine = transcriptionEngine
    self.modelPackageStore = modelPackageStore
    self.modelPackageDownloadTransport = modelPackageDownloadTransport
    self.recoverPendingAudio = recoverPendingAudio
    preferencesDefaults = userDefaults
    fillerWordRemovalEnabled =
      userDefaults.object(forKey: Self.fillerWordRemovalKey) as? Bool ?? true
    customWords = userDefaults.stringArray(forKey: Self.customWordsKey) ?? []
    languageSelection = ModelLanguageSelection(
      intent: userDefaults.string(forKey: Self.languageIntentKey) ?? "auto"
    )
  }

  #if DEBUG
    func resetTranscriptionPreferencesForUITests() {
      preferencesDefaults.removeObject(forKey: Self.fillerWordRemovalKey)
      preferencesDefaults.removeObject(forKey: Self.customWordsKey)
      fillerWordRemovalEnabled = true
      customWords = []
    }
  #endif

  func setFillerWordRemovalEnabled(_ enabled: Bool) {
    fillerWordRemovalEnabled = enabled
    preferencesDefaults.set(enabled, forKey: Self.fillerWordRemovalKey)
  }

  func addCustomWord(_ word: String) throws {
    let normalizedWord = Self.normalizeCustomWord(word)
    guard !normalizedWord.isEmpty else {
      throw CustomWordPreferenceError.invalid
    }
    guard normalizedWord.count <= 50 else {
      throw CustomWordPreferenceError.tooLong
    }
    guard
      !customWords.contains(where: { $0.caseInsensitiveCompare(normalizedWord) == .orderedSame })
    else {
      throw CustomWordPreferenceError.duplicate(word: normalizedWord)
    }

    customWords.append(normalizedWord)
    preferencesDefaults.set(customWords, forKey: Self.customWordsKey)
  }

  func removeCustomWord(_ word: String) {
    customWords.removeAll { $0 == word }
    preferencesDefaults.set(customWords, forKey: Self.customWordsKey)
  }

  private static func normalizeCustomWord(_ word: String) -> String {
    let filtered = word.filter { !"<>\"'".contains($0) }
    return filtered.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  var availableLanguages: [String] {
    languageSelection.options
  }

  var hasLanguageSelection: Bool {
    availableLanguages.count > 1
  }

  var languagePickerSelection: String? {
    languageSelection.pickerSelection
  }

  func selectLanguage(_ intent: String) {
    guard languageSelection.options.contains(intent) else {
      return
    }
    languageSelection.intent = intent
    preferencesDefaults.set(intent, forKey: Self.languageIntentKey)
  }

  func restoreLocalStateIfPresent() async {
    guard !hasAttemptedLocalRestore else {
      return
    }
    hasAttemptedLocalRestore = true
    var recoveredAudioHasLengthFailure = false
    do {
      if let audioFile = try recoverPendingAudio() {
        pendingAudioFile = audioFile
        if UserDefaults.standard.bool(forKey: pendingAudioSavedKey) {
          noticeKey = "iosApp.audioCleanupFailed"
        } else if UserDefaults.standard.string(forKey: pendingAudioFailureKey) == "input-too-long" {
          recoveredAudioHasLengthFailure = true
          errorKey = "iosApp.audioTooLong"
          state = .failed("iosApp.audioTooLong")
        } else {
          canRetryPendingTranscription = true
          state = .failed("iosApp.audioInterrupted")
          noticeKey = "iosApp.recoveredRecording"
        }
      } else {
        UserDefaults.standard.removeObject(forKey: pendingAudioSavedKey)
        UserDefaults.standard.removeObject(forKey: pendingAudioFailureKey)
      }
    } catch {
      errorKey = "iosApp.genericError"
    }

    guard let modelPath = preferencesDefaults.string(forKey: modelPathKey) else {
      return
    }
    guard let packageID = preferencesDefaults.string(forKey: modelPackageIDKey),
      let packageVersion = preferencesDefaults.string(forKey: modelPackageVersionKey)
    else {
      clearSavedModelPreferences()
      errorKey = "iosApp.modelMissing"
      return
    }

    let modelURL = URL(fileURLWithPath: modelPath)
    let packageStore: ModelPackageStore
    do {
      packageStore = try modelPackageStore ?? ModelPackageStore.applicationStore()
    } catch {
      errorKey = "iosApp.genericError"
      return
    }

    let package: InstalledModelPackage
    do {
      package = try await packageStore.resolveInstalledPackage(
        id: packageID,
        version: packageVersion
      )
      guard
        package.manifest.files.contains(where: { file in
          package.directoryURL.appendingPathComponent(file.relativePath).standardizedFileURL.path
            == modelURL.standardizedFileURL.path
        })
      else {
        throw ModelPackageStoreError.installedPackageMismatch
      }
    } catch {
      clearSavedModelPreferences()
      errorKey = "iosApp.modelPackageDamaged"
      return
    }

    let probe = probeModelFile(path: modelURL.path)
    guard probe.verdict != .unsupported else {
      clearSavedModelPreferences()
      errorKey = "iosApp.invalidModel"
      return
    }

    do {
      try await transcriptionEngine.loadModel(at: modelURL)
      languageSelection.updateCapabilities(probe)
      isModelLoaded = true
      if !recoveredAudioHasLengthFailure {
        errorKey = nil
      }
    } catch {
      errorKey = "iosApp.genericError"
    }
  }

  #if DEBUG
    func importLocalModel(from sourceURL: URL) async {
      let hasScopedAccess = sourceURL.startAccessingSecurityScopedResource()
      defer {
        if hasScopedAccess {
          sourceURL.stopAccessingSecurityScopedResource()
        }
      }

      do {
        let sourceIntegrity = try verifyFileIntegrity(
          path: sourceURL.path,
          expectedSizeBytes: nil,
          expectedSha256: nil
        )
        let manifest = ModelPackageManifest(
          id: "local-import-\(UUID().uuidString)",
          version: "1",
          files: [
            ModelPackageFile(
              relativePath: "model.gguf",
              sizeBytes: sourceIntegrity.sizeBytes,
              sha256: sourceIntegrity.sha256
            )
          ]
        )
        let packageStore = try modelPackageStore ?? ModelPackageStore.applicationStore()
        let stagingDirectory = try await packageStore.prepareStagingDirectory(for: manifest)
        var stagingDirectoryForCleanup: URL? = stagingDirectory
        defer {
          if let stagingDirectoryForCleanup {
            try? FileManager.default.removeItem(at: stagingDirectoryForCleanup)
          }
        }

        let stagedModelURL = stagingDirectory.appendingPathComponent("model.gguf")
        try FileManager.default.copyItem(at: sourceURL, to: stagedModelURL)
        let installedPackage = try await packageStore.commit(manifest, from: stagingDirectory)
        stagingDirectoryForCleanup = nil
        let modelURL = installedPackage.directoryURL.appendingPathComponent("model.gguf")
        let probe = probeModelFile(path: modelURL.path)
        guard probe.verdict != .unsupported else {
          try await packageStore.remove(id: manifest.id, version: manifest.version)
          errorKey = "iosApp.invalidModel"
          return
        }
        do {
          try await transcriptionEngine.loadModel(at: modelURL)
        } catch {
          try await packageStore.remove(id: manifest.id, version: manifest.version)
          throw error
        }
        languageSelection.updateCapabilities(probe)
        preferencesDefaults.set(modelURL.path, forKey: modelPathKey)
        preferencesDefaults.set(sourceURL.lastPathComponent, forKey: modelNameKey)
        preferencesDefaults.set(manifest.id, forKey: modelPackageIDKey)
        preferencesDefaults.set(manifest.version, forKey: modelPackageVersionKey)
        isModelLoaded = true
        errorKey = nil
      } catch {
        errorKey = "iosApp.genericError"
      }
    }
  #endif

  #if DEBUG
    var canInstallCatalogModel: Bool {
      !isInstallingCatalogModel
        && !isLoadingCatalogModel
        && !isEvaluatingAudio
        && state != .recording
        && state != .requestingPermission
        && state != .transcribing
    }

    func installCatalogModel(model: ModelDescriptor, file: QuantFile) async {
      guard canInstallCatalogModel else {
        return
      }

      let installID = UUID()
      catalogModelInstallID = installID
      isInstallingCatalogModel = true
      isLoadingCatalogModel = false
      catalogModelDownloadProgress = nil
      catalogModelInstallErrorKey = nil
      defer {
        catalogModelInstallTask = nil
        catalogModelInstallID = nil
        catalogModelDownloadProgress = nil
        isInstallingCatalogModel = false
        isLoadingCatalogModel = false
      }

      do {
        let download = try makeCatalogModelPackageDownload(model: model, file: file)
        let packageStore = try modelPackageStore ?? ModelPackageStore.applicationStore()
        let installer = ModelPackageInstaller(
          store: packageStore,
          transport: modelPackageDownloadTransport
        )
        let updateProgress: @Sendable (ModelPackageDownloadProgress) -> Void = {
          [weak self] progress in
          Task { @MainActor [weak self] in
            guard self?.catalogModelInstallID == installID else {
              return
            }
            self?.catalogModelDownloadProgress = progress
          }
        }
        let installTask = Task<InstalledModelPackage, Error> { [weak self] in
          guard let self else {
            throw CancellationError()
          }
          return try await self.installOrReuseCatalogPackage(
            download.manifest,
            sources: download.sources,
            in: packageStore,
            using: installer,
            progress: updateProgress
          )
        }
        catalogModelInstallTask = installTask
        let installedPackage: InstalledModelPackage
        do {
          installedPackage = try await withTaskCancellationHandler {
            try await installTask.value
          } onCancel: {
            installTask.cancel()
          }
        } catch {
          if error is CancellationError || (error as? URLError)?.code == .cancelled {
            return
          }
          throw error
        }

        catalogModelInstallTask = nil
        isInstallingCatalogModel = false
        isLoadingCatalogModel = true
        let modelURL = installedPackage.directoryURL.appendingPathComponent(file.filename)
        let probe = probeModelFile(path: modelURL.path)
        guard probe.verdict != .unsupported else {
          try await packageStore.remove(
            id: installedPackage.manifest.id,
            version: installedPackage.manifest.version
          )
          catalogModelInstallErrorKey = "iosApp.invalidModel"
          return
        }

        try await transcriptionEngine.loadModel(at: modelURL)
        languageSelection.updateCapabilities(probe)
        preferencesDefaults.set(modelURL.path, forKey: modelPathKey)
        preferencesDefaults.set("\(model.name) · \(file.quant)", forKey: modelNameKey)
        preferencesDefaults.set(installedPackage.manifest.id, forKey: modelPackageIDKey)
        preferencesDefaults.set(installedPackage.manifest.version, forKey: modelPackageVersionKey)
        isModelLoaded = true
        errorKey = nil
      } catch {
        catalogModelInstallErrorKey = "iosApp.genericError"
      }
    }

    func cancelCatalogModelInstall() {
      catalogModelInstallTask?.cancel()
    }

    private func installOrReuseCatalogPackage(
      _ manifest: ModelPackageManifest,
      sources: [ModelPackageDownloadSource],
      in store: ModelPackageStore,
      using installer: ModelPackageInstaller,
      progress: @escaping @Sendable (ModelPackageDownloadProgress) -> Void
    ) async throws -> InstalledModelPackage {
      do {
        let installed = try await store.resolveInstalledPackage(
          id: manifest.id,
          version: manifest.version
        )
        do {
          for file in installed.manifest.files {
            let fileURL = installed.directoryURL.appendingPathComponent(file.relativePath)
            _ = try verifyFileIntegrity(
              path: fileURL.path,
              expectedSizeBytes: file.sizeBytes,
              expectedSha256: file.sha256
            )
          }
          return installed
        } catch {
          try await store.remove(id: manifest.id, version: manifest.version)
        }
      } catch ModelPackageStoreError.packageNotInstalled {
      } catch ModelPackageStoreError.installedPackageMismatch {
        try await store.remove(id: manifest.id, version: manifest.version)
      }
      return try await installer.install(manifest, from: sources, progress: progress)
    }
  #endif

  private func clearSavedModelPreferences() {
    preferencesDefaults.removeObject(forKey: modelPathKey)
    preferencesDefaults.removeObject(forKey: modelNameKey)
    preferencesDefaults.removeObject(forKey: modelPackageIDKey)
    preferencesDefaults.removeObject(forKey: modelPackageVersionKey)
  }

  #if DEBUG
    func evaluateAudio(from sourceURL: URL, referenceText: String = "") async {
      guard isModelLoaded,
        !isEvaluatingAudio,
        state != .recording,
        state != .requestingPermission,
        state != .transcribing
      else {
        return
      }

      let hasScopedAccess = sourceURL.startAccessingSecurityScopedResource()
      defer {
        if hasScopedAccess {
          sourceURL.stopAccessingSecurityScopedResource()
        }
      }

      isEvaluatingAudio = true
      evaluation = nil
      evaluationErrorKey = nil
      defer {
        isEvaluatingAudio = false
      }

      let resourceMonitor = DeviceResourceMonitor()
      resourceMonitor.start()
      do {
        let result = try await transcriptionEngine.transcribe(
          fileAt: sourceURL,
          language: languageSelection.transcriptionLanguage,
          progress: { _ in }
        )
        let resourceMeasurement = resourceMonitor.stop()
        let modelPath = preferencesDefaults.string(forKey: modelPathKey)
        let modelName =
          preferencesDefaults.string(forKey: modelNameKey)
          ?? modelPath.map { URL(fileURLWithPath: $0).lastPathComponent }
          ?? "unknown"
        let audioHashTask = Task {
          await InferenceEvaluation.sha256(at: sourceURL)
        }
        let modelHash: String?
        if let modelPath {
          modelHash = await InferenceEvaluation.sha256(at: URL(fileURLWithPath: modelPath))
        } else {
          modelHash = nil
        }
        evaluation = InferenceEvaluation(
          audioFileName: sourceURL.lastPathComponent,
          audioFileSizeBytes: fileSize(at: sourceURL) ?? 0,
          audioSHA256: await audioHashTask.value,
          modelName: modelName,
          modelFileSizeBytes: modelPath.flatMap { fileSize(at: URL(fileURLWithPath: $0)) },
          modelSHA256: modelHash,
          languageIntent: languageSelection.intent,
          resolvedLanguage: languageSelection.resolvedLanguage,
          deviceIdentifier: deviceIdentifier,
          operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
          audioDurationMs: result.audioDurationMs,
          processingDurationMs: result.processingDurationMs,
          transcript: result.text,
          referenceText: referenceText,
          peakSampledMemoryFootprintBytes: resourceMeasurement.peakSampledMemoryFootprintBytes,
          thermalStates: resourceMeasurement.thermalStates,
          memorySampleIntervalMs: resourceMeasurement.sampleIntervalMs
        )
      } catch {
        _ = resourceMonitor.stop()
        evaluationErrorKey = "iosApp.evaluationFailed"
      }
    }

    private var deviceIdentifier: String {
      var systemInfo = utsname()
      guard uname(&systemInfo) == 0 else {
        return "unknown"
      }
      return withUnsafeBytes(of: systemInfo.machine) { bytes in
        let identifier = bytes.bindMemory(to: CChar.self)
        return String(
          decoding: identifier.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
          as: UTF8.self
        )
      }
    }

    private func fileSize(at url: URL) -> Int64? {
      guard
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
        let size = attributes[.size] as? NSNumber
      else {
        return nil
      }
      return size.int64Value
    }
  #endif

  func startRecording() async {
    guard isModelLoaded else {
      errorKey = "iosApp.modelMissing"
      return
    }
    guard pendingAudioFile == nil, pendingTranscriptRecord == nil else {
      return
    }
    let permissionRequestState = DictationStateMachine.reduce(
      state,
      event: .requestPermission
    )
    guard permissionRequestState == .requestingPermission else {
      return
    }
    state = permissionRequestState
    do {
      try await audioCapture.startRecording()
      selectedRecord = nil
      transcript = ""
      UserDefaults.standard.removeObject(forKey: pendingAudioFailureKey)
      recordingStartedAt = .now
      errorKey = nil
      noticeKey = nil
      state = DictationStateMachine.reduce(state, event: .permissionGranted)
    } catch AudioCaptureError.microphonePermissionDenied {
      errorKey = "iosApp.permissionDenied"
      state = DictationStateMachine.reduce(
        state,
        event: .failed("iosApp.permissionDenied")
      )
    } catch {
      errorKey = "iosApp.genericError"
      state = DictationStateMachine.reduce(state, event: .failed("iosApp.genericError"))
    }
  }

  func stopAndTranscribe(using context: ModelContext) {
    guard state == .recording else {
      return
    }
    do {
      let capture = try audioCapture.stopRecording()
      pendingAudioFile = capture.audioFile
      pendingAudioTranscriptRecordID = nil
      canRetryPendingTranscription = true
      UserDefaults.standard.removeObject(forKey: pendingAudioSavedKey)
      recordingStartedAt = nil
      state = DictationStateMachine.reduce(state, event: .stopRecording)
      errorKey = nil
      noticeKey =
        switch capture.warning {
        case .recordingMayBeIncomplete:
          "iosApp.recordingMayBeIncomplete"
        case .insufficientStorage:
          "iosApp.recordingInsufficientStorage"
        case nil:
          nil
        }
      transcriptionTask = Task { [weak self] in
        await self?.transcribe(capture.audioFile, using: context)
      }
    } catch {
      recordingStartedAt = nil
      errorKey = "iosApp.genericError"
      state = DictationStateMachine.reduce(state, event: .failed("iosApp.genericError"))
    }
  }

  func handleRecordingInterruption(messageKey: String) {
    guard state == .recording else {
      return
    }
    do {
      let capture = try audioCapture.stopRecording()
      pendingAudioFile = capture.audioFile
      pendingAudioTranscriptRecordID = nil
      canRetryPendingTranscription = true
      UserDefaults.standard.removeObject(forKey: pendingAudioSavedKey)
      recordingStartedAt = nil
      errorKey = nil
      noticeKey = messageKey
      state = DictationStateMachine.reduce(state, event: .interrupted(messageKey))
    } catch {
      recordingStartedAt = nil
      errorKey = "iosApp.genericError"
      state = DictationStateMachine.reduce(state, event: .failed("iosApp.genericError"))
    }
  }

  func handleAppBackground() {
    if state == .recording {
      handleRecordingInterruption(messageKey: "iosApp.recordingStoppedBackground")
    } else if state == .transcribing {
      transcriptionEngine.cancel()
      canRetryPendingTranscription = true
      errorKey = nil
      noticeKey = "iosApp.backgroundTranscriptionStopped"
      state = DictationStateMachine.reduce(
        state,
        event: .failed("iosApp.backgroundTranscriptionStopped")
      )
    } else {
      #if DEBUG
        if isEvaluatingAudio {
          transcriptionEngine.cancel()
          evaluationErrorKey = "iosApp.evaluationFailed"
        }
      #endif
    }
  }

  func retryTranscription(using context: ModelContext) {
    guard hasPendingAudioRecovery,
      let pendingAudioFile
    else {
      return
    }
    canRetryPendingTranscription = false
    UserDefaults.standard.removeObject(forKey: pendingAudioFailureKey)
    errorKey = nil
    state = DictationStateMachine.reduce(state, event: .retryTranscription)
    transcriptionTask = Task { [weak self] in
      await self?.transcribe(pendingAudioFile, using: context)
    }
  }

  func handleIncompleteTranscription(kind: IncompleteOutputKind, partialText: String?) {
    canRetryPendingTranscription = true
    UserDefaults.standard.removeObject(forKey: pendingAudioFailureKey)
    if let partialText,
      !partialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      selectedRecord = nil
      transcript = partialText
      canSavePartialTranscript = true
    } else {
      transcript = ""
      canSavePartialTranscript = false
    }

    let messageKey =
      switch kind {
      case .truncated:
        "iosApp.transcriptionTruncated"
      case .repetition:
        "iosApp.transcriptionRepeated"
      }
    errorKey = messageKey
    state = .failed(messageKey)
  }

  func handleInputTooLong() {
    canRetryPendingTranscription = false
    UserDefaults.standard.set("input-too-long", forKey: pendingAudioFailureKey)
    let messageKey = "iosApp.audioTooLong"
    errorKey = messageKey
    state = .failed(messageKey)
  }

  func savePartialTranscript(using context: ModelContext) {
    guard hasPartialTranscriptToSave else {
      return
    }
    let record = TranscriptRecord(text: transcript)
    context.insert(record)
    selectedRecord = record
    pendingTranscriptRecord = record
    pendingAudioTranscriptRecordID = pendingAudioFile == nil ? nil : record.id
    canSavePartialTranscript = false
    canRetryPendingTranscription = false
    state = .transcript(transcript)
    savePendingTranscript(using: context)
  }

  func discardPendingAudio() {
    guard hasDiscardablePendingAudio, let pendingAudioFile else {
      return
    }
    do {
      try pendingAudioFile.remove()
      self.pendingAudioFile = nil
      pendingAudioTranscriptRecordID = nil
      canRetryPendingTranscription = false
      UserDefaults.standard.removeObject(forKey: pendingAudioSavedKey)
      UserDefaults.standard.removeObject(forKey: pendingAudioFailureKey)
      errorKey = nil
      noticeKey = nil
      if case .failed = state {
        state = .ready
      }
    } catch {
      errorKey = "iosApp.genericError"
    }
  }

  func savePendingTranscript(using context: ModelContext) {
    guard let pendingTranscriptRecord else {
      return
    }
    do {
      try context.save()
      self.pendingTranscriptRecord = nil
      errorKey = nil
      removePendingAudioAfterPersistence(for: pendingTranscriptRecord)
    } catch {
      transcript = pendingTranscriptRecord.text
      state = .transcript(pendingTranscriptRecord.text)
      errorKey = "iosApp.genericError"
    }
  }

  func cancelTranscription() {
    transcriptionEngine.cancel()
  }

  func recordingDuration(at date: Date) -> Int {
    guard let recordingStartedAt else {
      return 0
    }
    return max(0, Int(date.timeIntervalSince(recordingStartedAt)))
  }

  func select(_ record: TranscriptRecord) {
    selectedRecord = record
    transcript = record.text
    canSavePartialTranscript = false
    state = .transcript(record.text)
    errorKey = nil
  }

  func clearTranscriptAfterHistoryDeletion() {
    guard !hasPendingTranscriptSave,
      state != .requestingPermission,
      state != .recording,
      state != .transcribing
    else {
      return
    }

    selectedRecord = nil
    transcript = ""
    guard pendingAudioFile == nil else {
      return
    }
    state = .ready
    errorKey = nil
    noticeKey = nil
  }

  func updateTranscript(_ value: String, using context: ModelContext) {
    transcript = value
    state = .transcript(value)
    guard let selectedRecord else {
      return
    }
    selectedRecord.text = value
    pendingTranscriptRecord = selectedRecord
    editSaveTask?.cancel()
    editSaveTask = Task {
      do {
        try await Task.sleep(for: .milliseconds(300))
        savePendingTranscript(using: context)
      } catch is CancellationError {
        return
      } catch {
        errorKey = "iosApp.genericError"
      }
    }
  }

  func delete(_ record: TranscriptRecord, using context: ModelContext) {
    let transcriptUsesPendingAudio = pendingAudioTranscriptRecordID == record.id
    context.delete(record)
    do {
      try context.save()
      if pendingTranscriptRecord?.id == record.id {
        pendingTranscriptRecord = nil
      }
      if transcriptUsesPendingAudio {
        removePendingAudioAfterPersistence(for: record)
      }
      if selectedRecord?.id == record.id {
        selectedRecord = nil
        transcript = ""
        state = .ready
      }
    } catch {
      errorKey = "iosApp.genericError"
    }
  }

  private func transcribe(_ audioFile: TemporaryAudioFile, using context: ModelContext) async {
    state = .transcribing
    transcriptionProgress = .preparingAudio
    defer { transcriptionProgress = nil }
    do {
      let result = try await transcriptionEngine.transcribe(
        fileAt: audioFile.url,
        language: languageSelection.transcriptionLanguage,
        progress: { [weak self] progress in
          self?.transcriptionProgress = progress
        }
      )
      let processedText = postProcessTranscript(
        result.text, detectedLanguage: result.detectedLanguage)
      guard !processedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        canRetryPendingTranscription = true
        let messageKey = "iosApp.emptyTranscription"
        errorKey = messageKey
        state = .failed(messageKey)
        return
      }
      storeTranscript(
        processedText,
        detectedLanguage: result.detectedLanguage,
        audioDurationMs: result.audioDurationMs,
        processingDurationMs: result.processingDurationMs,
        using: context
      )
    } catch TranscriptionEngineError.cancelled(partialText: let partialText) {
      if let partialText, !partialText.isEmpty {
        let processedText = postProcessTranscript(partialText, detectedLanguage: nil)
        if !processedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          storeTranscript(processedText, using: context)
        } else {
          canRetryPendingTranscription = true
          state = .ready
        }
      } else {
        canRetryPendingTranscription = true
        state = .ready
      }
    } catch TranscriptionEngineError.incompleteOutput(let kind, let partialText) {
      handleIncompleteTranscription(kind: kind, partialText: partialText)
    } catch TranscriptionEngineError.inputTooLong {
      handleInputTooLong()
    } catch {
      canRetryPendingTranscription = true
      errorKey = "iosApp.genericError"
      state = DictationStateMachine.reduce(state, event: .failed("iosApp.genericError"))
    }
  }

  private func postProcessTranscript(_ text: String, detectedLanguage: String?) -> String {
    postProcessTranscription(
      text: text,
      options: TranscriptPostProcessingOptions(
        customWords: customWords,
        correctionThreshold: 0.18,
        languageCode: languageSelection.transcriptionLanguage ?? detectedLanguage,
        customFillerWords: nil,
        fillerRemovalEnabled: fillerWordRemovalEnabled
      )
    )
  }

  private func storeTranscript(
    _ text: String,
    detectedLanguage: String? = nil,
    audioDurationMs: UInt64 = 0,
    processingDurationMs: UInt64 = 0,
    using context: ModelContext
  ) {
    let record = TranscriptRecord(
      text: text,
      detectedLanguage: detectedLanguage,
      audioDurationMs: Int64(clamping: audioDurationMs),
      processingDurationMs: Int64(clamping: processingDurationMs)
    )
    context.insert(record)
    selectedRecord = record
    pendingTranscriptRecord = record
    pendingAudioTranscriptRecordID = pendingAudioFile == nil ? nil : record.id
    canSavePartialTranscript = false
    canRetryPendingTranscription = false
    UserDefaults.standard.removeObject(forKey: pendingAudioFailureKey)
    transcript = text
    state = .transcript(text)
    savePendingTranscript(using: context)
  }

  private func removePendingAudioAfterPersistence(for record: TranscriptRecord) {
    guard pendingAudioTranscriptRecordID == record.id,
      let pendingAudioFile
    else {
      return
    }
    UserDefaults.standard.set(true, forKey: pendingAudioSavedKey)
    do {
      try pendingAudioFile.remove()
      self.pendingAudioFile = nil
      pendingAudioTranscriptRecordID = nil
      canRetryPendingTranscription = false
      UserDefaults.standard.removeObject(forKey: pendingAudioSavedKey)
      UserDefaults.standard.removeObject(forKey: pendingAudioFailureKey)
    } catch {
      noticeKey = "iosApp.audioCleanupFailed"
    }
  }
}
