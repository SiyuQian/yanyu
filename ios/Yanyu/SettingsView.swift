import SwiftData
import SwiftUI

struct SettingsView: View {
  @Environment(DictationViewModel.self) private var viewModel
  @Environment(\.modelContext) private var modelContext
  @AppStorage("yanyu.ios.appearance") private var appearance = AppearancePreference.system.rawValue
  @Query(sort: \TranscriptRecord.createdAt, order: .reverse)
  private var transcripts: [TranscriptRecord]

  @State private var isDeleteConfirmationPresented = false
  @State private var isDeleteErrorPresented = false
  @State private var customWordDraft = ""
  @State private var customWordError: CustomWordPreferenceError?

  private var canDeleteHistory: Bool {
    !transcripts.isEmpty
      && viewModel.state != .requestingPermission
      && viewModel.state != .recording
      && viewModel.state != .transcribing
      && !viewModel.hasPendingTranscriptSave
  }

  var body: some View {
    Form {
      Section {
        Text("iosApp.appearanceSection")
          .font(.title3.weight(.semibold))
          .foregroundStyle(.primary)
        Picker(
          "iosApp.appearance",
          selection: Binding(
            get: { AppearancePreference.resolve(appearance).rawValue },
            set: { appearance = $0 }
          )
        ) {
          Text("iosApp.appearanceSystem").tag(AppearancePreference.system.rawValue)
          Text("iosApp.appearanceLight").tag(AppearancePreference.light.rawValue)
          Text("iosApp.appearanceDark").tag(AppearancePreference.dark.rawValue)
        }
        .tint(.primary)
      }

      Section {
        Toggle(
          "settings.advanced.fillerWordRemoval.title",
          isOn: Binding(
            get: { viewModel.fillerWordRemovalEnabled },
            set: { viewModel.setFillerWordRemovalEnabled($0) }
          )
        )
        Text("settings.advanced.fillerWordRemoval.description")
          .font(.body)
          .foregroundStyle(.primary)
      }

      Section {
        Text("settings.advanced.customWords.title")
          .font(.title3.weight(.semibold))
          .foregroundStyle(.primary)
        Text("settings.advanced.customWords.description")
          .font(.body)
          .foregroundStyle(.primary)

        HStack {
          TextField("settings.advanced.customWords.placeholder", text: $customWordDraft)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.done)
            .onSubmit(addCustomWord)
          Button("settings.advanced.customWords.add", action: addCustomWord)
            .disabled(customWordDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }

        if let customWordError, let message = customWordErrorMessage(for: customWordError) {
          Text(message)
            .font(.footnote)
            .foregroundStyle(.red)
            .accessibilityIdentifier("customWordError")
        }

        ForEach(viewModel.customWords, id: \.self) { word in
          HStack {
            Text(word)
            Spacer()
            Button(role: .destructive) {
              viewModel.removeCustomWord(word)
            } label: {
              Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text(removeCustomWordLabel(for: word)))
          }
        }
      }

      Section {
        Text("iosApp.privacySection")
          .font(.title3.weight(.semibold))
          .foregroundStyle(.primary)
        Text("iosApp.privacyOnDevice")
          .font(.headline)
        Text("iosApp.privacyOnDeviceBody")
          .font(.body)
          .foregroundStyle(.primary)

        Text("iosApp.privacyAudio")
          .font(.headline)
        Text("iosApp.privacyAudioBody")
          .font(.body)
          .foregroundStyle(.primary)

        Text("iosApp.privacyHistory")
          .font(.headline)
        Text("iosApp.privacyHistoryBody")
          .font(.body)
          .foregroundStyle(.primary)
      }

      Section {
        Text("iosApp.historyPrivacySection")
          .font(.title3.weight(.semibold))
          .foregroundStyle(.primary)
        if transcripts.isEmpty {
          Text("iosApp.noHistoryToDelete")
            .font(.body)
            .foregroundStyle(.primary)
        } else if canDeleteHistory {
          Button("iosApp.deleteAllHistory", role: .destructive) {
            isDeleteConfirmationPresented = true
          }
          Text("iosApp.deleteAllHistoryHint")
            .font(.body)
            .foregroundStyle(.primary)
        } else {
          Text("iosApp.finishBeforeDeleteHistory")
            .font(.body)
            .foregroundStyle(.primary)
        }
      }
    }
    .navigationTitle("iosApp.settingsTitle")
    .confirmationDialog(
      "iosApp.deleteAllHistoryConfirmation",
      isPresented: $isDeleteConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("iosApp.deleteAllHistory", role: .destructive) {
        deleteAllHistory()
      }
      Button("iosApp.settingsCancel", role: .cancel) {}
    }
    .alert("iosApp.deleteHistoryFailedTitle", isPresented: $isDeleteErrorPresented) {
      Button("iosApp.settingsOK", role: .cancel) {}
    } message: {
      Text("iosApp.deleteHistoryFailedBody")
    }
  }

  private func deleteAllHistory() {
    guard canDeleteHistory else {
      return
    }
    do {
      try TranscriptStore.deleteAllHistory(using: modelContext)
      viewModel.clearTranscriptAfterHistoryDeletion()
    } catch {
      isDeleteErrorPresented = true
    }
  }

  private func addCustomWord() {
    do {
      try viewModel.addCustomWord(customWordDraft)
      customWordDraft = ""
      customWordError = nil
    } catch let error as CustomWordPreferenceError {
      customWordError = error
    } catch {
      customWordError = .invalid
    }
  }

  private func customWordErrorMessage(for error: CustomWordPreferenceError) -> String? {
    return switch error {
    case .invalid:
      String(localized: "settings.advanced.customWords.invalid")
    case .tooLong:
      String(localized: "settings.advanced.customWords.tooLong")
    case .duplicate(let word):
      String(localized: "settings.advanced.customWords.duplicate")
        .replacingOccurrences(of: "{{word}}", with: word)
    }
  }

  private func removeCustomWordLabel(for word: String) -> String {
    String(localized: "settings.advanced.customWords.remove")
      .replacingOccurrences(of: "{{word}}", with: word)
  }

}
