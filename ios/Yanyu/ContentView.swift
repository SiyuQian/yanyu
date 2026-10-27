import AVFAudio
import Foundation
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
  @Environment(DictationViewModel.self) private var viewModel
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.modelContext) private var modelContext
  @Environment(\.openURL) private var openURL
  @Query(sort: \TranscriptRecord.createdAt, order: .reverse)
  private var records: [TranscriptRecord]
  @AppStorage("yanyu.ios.onboarding-complete") private var hasCompletedOnboarding = false

  @State private var isModelImporterPresented = false
  #if DEBUG
    @State private var isEvaluationAudioImporterPresented = false
    @State private var evaluationReferenceText = ""
  #endif
  @State private var searchText = ""
  @State private var hasCopiedTranscript = false

  private var visibleRecords: [TranscriptRecord] {
    guard !searchText.isEmpty else {
      return records
    }
    return records.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
  }

  private var recordingControlTint: Color {
    viewModel.state == .recording
      ? Color(red: 0.69, green: 0.0, blue: 0.12)
      : Color(red: 0.04, green: 0.22, blue: 0.56)
  }

  var body: some View {
    NavigationStack {
      Group {
        if hasCompletedOnboarding {
          dictationScreen
        } else {
          onboardingScreen
        }
      }
      .navigationTitle("Yanyu")
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          if hasCompletedOnboarding {
            NavigationLink {
              SettingsView()
            } label: {
              Image(systemName: "gearshape")
            }
            .accessibilityLabel(Text("iosApp.settingsTitle"))
          }
        }
        ToolbarItem(placement: .topBarTrailing) {
          if hasCompletedOnboarding {
            Button {
              hasCompletedOnboarding = false
            } label: {
              Image(systemName: "info.circle")
            }
            .accessibilityLabel(Text("iosApp.onboardingTitle"))
          }
        }
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) {
      notification in
      guard
        let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
        AVAudioSession.InterruptionType(rawValue: rawType) == .began
      else {
        return
      }
      viewModel.handleRecordingInterruption(messageKey: "iosApp.audioInterrupted")
    }
    .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) {
      _ in
      viewModel.handleRecordingInterruption(messageKey: "iosApp.audioRouteChanged")
    }
    .onChange(of: scenePhase) { _, newPhase in
      if newPhase == .background {
        viewModel.handleAppBackground()
      }
    }
    .task {
      #if DEBUG
        prepareUITestHistoryIfRequested(using: modelContext)
      #endif
      await viewModel.restoreLocalStateIfPresent()
      #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--yanyu-ui-test-microphone-denied") {
          viewModel.errorKey = "iosApp.permissionDenied"
        }
      #endif
    }
    #if DEBUG
      .fileImporter(
        isPresented: $isModelImporterPresented,
        allowedContentTypes: [UTType(filenameExtension: "gguf") ?? .data],
        allowsMultipleSelection: false
      ) { result in
        switch result {
        case .success(let urls):
          guard let modelURL = urls.first else {
            return
          }
          Task {
            await viewModel.importLocalModel(from: modelURL)
          }
        case .failure:
          viewModel.errorKey = "iosApp.genericError"
        }
      }
    #endif
    #if DEBUG
      .fileImporter(
        isPresented: $isEvaluationAudioImporterPresented,
        allowedContentTypes: [UTType(filenameExtension: "wav") ?? .audio],
        allowsMultipleSelection: false
      ) { result in
        switch result {
        case .success(let urls):
          guard let audioURL = urls.first else {
            return
          }
          Task {
            await viewModel.evaluateAudio(
              from: audioURL,
              referenceText: evaluationReferenceText
            )
          }
        case .failure:
          viewModel.evaluationErrorKey = "iosApp.evaluationFailed"
        }
      }
    #endif
  }

  private var onboardingScreen: some View {
    VStack(spacing: 24) {
      Image(systemName: "waveform.and.mic")
        .font(.system(size: 54, weight: .medium))
        .foregroundStyle(.tint)
        .accessibilityHidden(true)
      Text("iosApp.onboardingTitle")
        .font(.title.weight(.semibold))
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
        .multilineTextAlignment(.center)
      Text("iosApp.onboardingBody")
        .font(.body)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      Button {
        hasCompletedOnboarding = true
      } label: {
        Text("iosApp.continue")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
    }
    .padding(28)
    .frame(maxWidth: 480)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var dictationScreen: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        Text("iosApp.tagline")
          .font(.subheadline)
          .foregroundStyle(.primary)
          .frame(maxWidth: .infinity, alignment: .leading)

        modelStatus
        #if DEBUG
          evaluationTools
        #endif
        recordingControls

        if viewModel.hasTranscriptForDisplay {
          transcriptEditor
        }

        historySection
      }
      .padding()
      .frame(maxWidth: 680)
      .frame(maxWidth: .infinity)
    }
    .background(Color(uiColor: .systemGroupedBackground))
  }

  private var modelStatus: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label {
        Text(viewModel.isModelLoaded ? "iosApp.modelReady" : "iosApp.modelMissing")
          .foregroundStyle(.primary)
      } icon: {
        Image(systemName: viewModel.isModelLoaded ? "checkmark.circle.fill" : "cpu")
          .foregroundStyle(viewModel.isModelLoaded ? .green : .secondary)
      }

      if viewModel.hasLanguageSelection {
        Picker(
          "iosApp.language",
          selection: Binding(
            get: { viewModel.languagePickerSelection ?? "" },
            set: { viewModel.selectLanguage($0) }
          )
        ) {
          ForEach(viewModel.availableLanguages, id: \.self) { language in
            languageOptionLabel(language).tag(language)
          }
        }
        .pickerStyle(.menu)
      }

      #if DEBUG
        Button {
          isModelImporterPresented = true
        } label: {
          Label("iosApp.importModel", systemImage: "square.and.arrow.down")
        }
        .buttonStyle(.bordered)
        .tint(.primary)
        Text("iosApp.importModelHint")
          .font(.caption)
          .foregroundStyle(.primary)

        catalogModelEvaluationControls

        Button {
          isEvaluationAudioImporterPresented = true
        } label: {
          Label("iosApp.evaluateAudio", systemImage: "waveform.badge.magnifyingglass")
        }
        .buttonStyle(.bordered)
        .tint(.primary)
        .disabled(
          !viewModel.isModelLoaded
            || viewModel.isEvaluatingAudio
            || viewModel.state == .recording
            || viewModel.state == .requestingPermission
            || viewModel.state == .transcribing
        )
        Text("iosApp.evaluateAudioHint")
          .font(.caption)
          .foregroundStyle(.primary)
      #endif

      if let errorKey = viewModel.errorKey {
        VStack(alignment: .leading, spacing: 8) {
          Text(LocalizedStringKey(errorKey))
            .font(.footnote)
            .foregroundStyle(.red)
            .accessibilityAddTraits(.updatesFrequently)

          if viewModel.shouldOfferSystemSettingsRecovery {
            Button("accessibility.openSettings") {
              if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                openURL(settingsURL)
              }
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("permissionSettingsRecovery")
          }
        }
      }
      if let noticeKey = viewModel.noticeKey {
        Text(LocalizedStringKey(noticeKey))
          .font(.footnote)
          .foregroundStyle(.orange)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.background, in: RoundedRectangle(cornerRadius: 16))
  }

  #if DEBUG
    private var catalogModelEvaluationControls: some View {
      Group {
        Text("iosApp.evaluationModelCatalog")
          .font(.subheadline.weight(.medium))

        if let model = bundledModelCatalog().first(where: { $0.name == "Qwen3-ASR 0.6B" }) {
          ForEach(model.files.filter { ["Q4_K_M", "Q8_0"].contains($0.quant) }, id: \.filename) {
            file in
            HStack {
              Button {
                Task {
                  await viewModel.installCatalogModel(model: model, file: file)
                }
              } label: {
                Label(
                  file.quant == "Q4_K_M"
                    ? "iosApp.downloadQ4Model"
                    : "iosApp.downloadQ8Model",
                  systemImage: "arrow.down.circle"
                )
              }
              .buttonStyle(.bordered)
              .tint(.primary)
              .disabled(!viewModel.canInstallCatalogModel)

              Spacer(minLength: 8)
              Text(
                "\(file.quant.replacingOccurrences(of: "_", with: " ")) · \(ByteCountFormatter.string(fromByteCount: Int64(clamping: file.sizeBytes), countStyle: .file))"
              )
              .font(.caption)
              .foregroundStyle(.primary)
              .multilineTextAlignment(.trailing)
            }
          }
        }

        if viewModel.isInstallingCatalogModel {
          if let progress = viewModel.catalogModelDownloadProgress {
            ProgressView(value: progress.fractionCompleted)
            Text(
              "\(ByteCountFormatter.string(fromByteCount: Int64(clamping: progress.completedBytes), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(clamping: progress.totalBytes), countStyle: .file))"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          } else {
            ProgressView("iosApp.downloadingModel")
          }
          Button("iosApp.cancelModelDownload", role: .cancel) {
            viewModel.cancelCatalogModelInstall()
          }
          .buttonStyle(.bordered)
        } else if viewModel.isLoadingCatalogModel {
          ProgressView("iosApp.loadingModel")
        }

        if let errorKey = viewModel.catalogModelInstallErrorKey {
          Text(LocalizedStringKey(errorKey))
            .font(.footnote)
            .foregroundStyle(.red)
        }
      }
    }
  #endif

  private func languageOptionLabel(_ language: String) -> Text {
    if language == "auto" {
      return Text("iosApp.languageAuto")
    }
    let baseLanguage = language.split(whereSeparator: { $0 == "-" || $0 == "_" }).first
    switch baseLanguage {
    case "en":
      return Text("iosApp.languageEnglish")
    case "zh":
      return Text("iosApp.languageChinese")
    default:
      return Text(language)
    }
  }

  #if DEBUG
    private var evaluationTools: some View {
      Group {
        TextField("iosApp.evaluationReference", text: $evaluationReferenceText, axis: .vertical)
          .lineLimit(2...4)
          .textFieldStyle(.roundedBorder)

        if viewModel.isEvaluatingAudio {
          ProgressView("iosApp.evaluatingAudio")
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        if let errorKey = viewModel.evaluationErrorKey {
          Text(LocalizedStringKey(errorKey))
            .font(.footnote)
            .foregroundStyle(.red)
        }

        if let evaluation = viewModel.evaluation {
          VStack(alignment: .leading, spacing: 12) {
            Text("iosApp.evaluationTitle")
              .font(.headline)
            evaluationRow(
              "iosApp.evaluationModel",
              value:
                "\(evaluation.modelName) (\(evaluation.modelFileSizeBytes.map(String.init) ?? NSLocalizedString("iosApp.metricUnavailable", comment: "")) bytes)"
            )
            evaluationRow("iosApp.evaluationDevice", value: evaluation.deviceIdentifier)
            evaluationRow("iosApp.evaluationSystem", value: evaluation.operatingSystemVersion)
            evaluationRow(
              "iosApp.evaluationAudio",
              value: "\(evaluation.audioFileName) · \(evaluation.audioDurationMs) ms"
            )
            evaluationRow(
              "iosApp.evaluationProcessing",
              value: "\(evaluation.processingDurationMs) ms"
            )
            evaluationRow(
              "iosApp.evaluationPeakMemory",
              value: evaluation.peakSampledMemoryFootprintBytes.map {
                let megabytes = Double($0) / 1_048_576
                return String(
                  format: "%.1f MB · %@ ms sampling",
                  locale: Locale(identifier: "en_US_POSIX"),
                  megabytes,
                  String(evaluation.memorySampleIntervalMs)
                )
              } ?? NSLocalizedString("iosApp.metricUnavailable", comment: "")
            )
            evaluationRow(
              "iosApp.evaluationThermalState",
              value: evaluation.thermalStates.isEmpty
                ? NSLocalizedString("iosApp.metricUnavailable", comment: "")
                : evaluation.thermalStates.joined(separator: " → ")
            )
            evaluationRow(
              "iosApp.evaluationRealtimeFactor",
              value: evaluation.realTimeFactor.map {
                String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), $0)
              } ?? NSLocalizedString("iosApp.metricUnavailable", comment: "")
            )
            evaluationRow(
              "iosApp.evaluationCharacterError",
              value: evaluation.characterError.map {
                let percentage = String(
                  format: "%.1f%%",
                  locale: Locale(identifier: "en_US_POSIX"),
                  $0.rate * 100
                )
                return "\(percentage) (\($0.editCount)/\($0.referenceCharacterCount))"
              } ?? NSLocalizedString("iosApp.metricUnavailable", comment: "")
            )
            Text("iosApp.evaluationTranscript")
              .font(.subheadline.weight(.medium))
            Text(
              evaluation.transcript.isEmpty
                ? NSLocalizedString("iosApp.metricUnavailable", comment: "")
                : evaluation.transcript
            )
            .font(.body)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            ShareLink(item: evaluation.report) {
              Label("iosApp.shareEvaluation", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
          }
          .padding(16)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(.background, in: RoundedRectangle(cornerRadius: 16))
        }
      }
    }

    private func evaluationRow(_ key: String, value: String) -> some View {
      HStack(alignment: .firstTextBaseline) {
        Text(LocalizedStringKey(key))
          .foregroundStyle(.secondary)
        Spacer(minLength: 12)
        Text(value)
          .multilineTextAlignment(.trailing)
          .textSelection(.enabled)
      }
      .font(.footnote)
    }
  #endif

  private var recordingControls: some View {
    VStack(spacing: 14) {
      if viewModel.state == .recording {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
          let elapsed = viewModel.recordingDuration(at: timeline.date)
          Text(String(format: "%02d:%02d", elapsed / 60, elapsed % 60))
            .font(.system(.title2, design: .monospaced).weight(.medium))
            .accessibilityLabel(Text("iosApp.stop"))
        }
        Label("iosApp.recording", systemImage: "waveform")
          .foregroundStyle(.red)
      } else if viewModel.state == .requestingPermission {
        ProgressView("iosApp.requestingPermission")
      } else if viewModel.state == .transcribing {
        if viewModel.transcriptionProgress == .preparingAudio {
          ProgressView("iosApp.preparingAudio")
        } else {
          ProgressView("iosApp.transcribing")
        }
        Button("iosApp.cancel", role: .cancel) {
          viewModel.cancelTranscription()
        }
      }

      Button {
        if viewModel.state == .recording {
          viewModel.stopAndTranscribe(using: modelContext)
        } else {
          hasCopiedTranscript = false
          Task { await viewModel.startRecording() }
        }
      } label: {
        Group {
          if viewModel.state == .recording {
            Label("iosApp.stop", systemImage: "stop.fill")
          } else {
            Label("iosApp.record", systemImage: "mic.fill")
          }
        }
        .foregroundStyle(.white)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .tint(recordingControlTint)
      .disabled(
        !viewModel.isModelLoaded
          || viewModel.state == .requestingPermission
          || viewModel.state == .transcribing
          || viewModel.hasPendingAudioRecovery
          || viewModel.hasDiscardablePendingAudio
          || viewModel.hasPendingTranscriptSave
      )

      if viewModel.hasPendingAudioRecovery {
        Button("iosApp.retryTranscription") {
          viewModel.retryTranscription(using: modelContext)
        }
        .buttonStyle(.bordered)
      }
      if viewModel.hasDiscardablePendingAudio && viewModel.state != .transcribing {
        Button("iosApp.discardRecording", role: .destructive) {
          viewModel.discardPendingAudio()
        }
        .buttonStyle(.bordered)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 8)
  }

  private var transcriptEditor: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("iosApp.transcriptTitle")
        .font(.headline)
      ZStack(alignment: .topLeading) {
        TextEditor(
          text: Binding(
            get: { viewModel.transcript },
            set: { viewModel.updateTranscript($0, using: modelContext) }
          )
        )
        .scrollContentBackground(.hidden)
        .accessibilityLabel(Text("iosApp.transcriptTitle"))

        if viewModel.transcript.isEmpty {
          Text("iosApp.transcriptPlaceholder")
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 12)
            .allowsHitTesting(false)
        }
      }
      .frame(minHeight: 180)
      .padding(8)
      .background(
        Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))

      HStack {
        Button {
          UIPasteboard.general.string = viewModel.transcript
          hasCopiedTranscript = true
        } label: {
          Label(
            hasCopiedTranscript ? "iosApp.copied" : "iosApp.copy",
            systemImage: hasCopiedTranscript ? "checkmark" : "doc.on.doc"
          )
        }
        .buttonStyle(.bordered)

        ShareLink(item: viewModel.transcript) {
          Label("iosApp.share", systemImage: "square.and.arrow.up")
        }
        .buttonStyle(.bordered)
      }

      if viewModel.hasPendingTranscriptSave {
        Button("iosApp.saveTranscript") {
          viewModel.savePendingTranscript(using: modelContext)
        }
        .buttonStyle(.borderedProminent)
      } else if viewModel.hasPartialTranscriptToSave {
        Button("iosApp.savePartialTranscript") {
          viewModel.savePartialTranscript(using: modelContext)
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.background, in: RoundedRectangle(cornerRadius: 16))
  }

  private var historySection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("iosApp.historyTitle")
        .font(.headline)
        .foregroundStyle(.primary)

      if records.isEmpty {
        Text("iosApp.historyEmpty")
          .font(.subheadline)
          .foregroundStyle(.primary)
      } else {
        TextField("iosApp.search", text: $searchText)
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel(Text("iosApp.search"))

        ForEach(visibleRecords) { record in
          HStack(spacing: 8) {
            Button {
              viewModel.select(record)
              hasCopiedTranscript = false
            } label: {
              VStack(alignment: .leading, spacing: 6) {
                Text(record.text)
                  .foregroundStyle(.primary)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .fixedSize(horizontal: false, vertical: true)
                Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                  .font(.caption)
                  .foregroundStyle(.primary)
                  .fixedSize(horizontal: false, vertical: true)
              }
              .padding(12)
              .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.hasPendingTranscriptSave || viewModel.hasPartialTranscriptToSave)

            Button(role: .destructive) {
              viewModel.delete(record, using: modelContext)
            } label: {
              Image(systemName: "trash")
                .frame(width: 44, height: 44)
            }
            .accessibilityLabel(Text("iosApp.delete"))
            .buttonStyle(.borderless)
            .disabled(viewModel.hasPendingTranscriptSave || viewModel.hasPartialTranscriptToSave)
          }
          .background(.background, in: RoundedRectangle(cornerRadius: 12))
          .contextMenu {
            Button("iosApp.delete", role: .destructive) {
              viewModel.delete(record, using: modelContext)
            }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  #if DEBUG
    private func prepareUITestHistoryIfRequested(using context: ModelContext) {
      let arguments = ProcessInfo.processInfo.arguments
      let shouldSeedHistory = arguments.contains("--yanyu-ui-test-seed-history")
      let shouldResetHistory = arguments.contains("--yanyu-ui-test-reset-history")
      let shouldResetPreferences = arguments.contains("--yanyu-ui-test-reset-preferences")
      guard shouldSeedHistory || shouldResetHistory || shouldResetPreferences else {
        return
      }

      if shouldResetPreferences {
        viewModel.resetTranscriptionPreferencesForUITests()
      }

      if shouldResetHistory {
        try? TranscriptStore.deleteAllHistory(using: context)
      }

      guard shouldSeedHistory else {
        return
      }

      guard
        let existingRecords = try? context.fetch(FetchDescriptor<TranscriptRecord>()),
        existingRecords.isEmpty
      else {
        return
      }

      context.insert(TranscriptRecord(text: "Quarterly planning: We should ship on Friday."))
      try? context.save()
    }
  #endif
}
