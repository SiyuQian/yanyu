import SwiftData
import SwiftUI
import UIKit

struct KeyboardSetupView: View {
  @Environment(DictationViewModel.self) private var viewModel
  @Environment(\.modelContext) private var modelContext
  @Environment(\.openURL) private var openURL
  let controller: KeyboardDictationController
  @State private var copiedPendingID: UUID?
  @State private var pendingActionFailed = false

  var body: some View {
    Form {
      if let pending = controller.pendingResult {
        pendingResultSection(pending)
      }
      Section {
        Label(
          viewModel.isModelLoaded ? "iosApp.modelReady" : "iosApp.modelMissing",
          systemImage: viewModel.isModelLoaded ? "checkmark.circle.fill" : "cpu"
        )
        if !viewModel.isModelLoaded {
          Text("iosApp.keyboardModelNeeded")
        }
        Text("iosApp.keyboardModeGuidance")
      } header: {
        Text("iosApp.prepareModelTitle")
      }
      Section {
        Text("iosApp.keyboardSetupInstructions")
          .accessibilityIdentifier("keyboardSetupInstructions")
        Button("accessibility.openSettings") {
          if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        }
      } header: {
        Text("iosApp.keyboardEnable")
      }
      Section {
        Text("iosApp.shortcutSetupInstructions")
          .accessibilityIdentifier("shortcutSetupInstructions")
      } header: {
        Text("iosApp.shortcutStartTitle")
      }
      Section {
        Text("iosApp.keyboardPrivacy")
        if controller.isActive {
          if viewModel.state == .recording {
            Label("iosApp.keyboardRecording", systemImage: "mic.fill")
              .foregroundStyle(.red)
            Button("iosApp.stop") {
              controller.prepareForTranscription(viewModel: viewModel)
              viewModel.stopAndTranscribe(using: modelContext)
            }
          } else {
            ProgressView("iosApp.transcribing")
          }
          Button("iosApp.cancel", role: .cancel) { controller.cancel(viewModel: viewModel) }
        } else {
          Button("iosApp.keyboardStartRecording") {
            Task {
              await controller.start(viewModel: viewModel)
              if UIApplication.shared.applicationState != .active {
                controller.cancel(viewModel: viewModel)
              }
            }
          }
          .accessibilityIdentifier("keyboardStartRecording")
          .disabled(
            !viewModel.isModelLoaded || viewModel.isPreparingModel || viewModel.state == .recording
              || viewModel.state == .requestingPermission || viewModel.state == .transcribing
              || viewModel.hasDiscardablePendingAudio || viewModel.hasPendingTranscriptSave
              || controller.pendingResult != nil
          )
        }
        if let errorKey = viewModel.errorKey {
          Text(LocalizedStringKey(errorKey)).foregroundStyle(.red)
        }
        if viewModel.hasPendingAudioRecovery {
          Text("iosApp.keyboardRecovery")
        }
      } header: {
        Text("iosApp.keyboardVoiceInput")
      }
    }
    .navigationTitle("iosApp.keyboardTitle")
  }

  private func pendingResultSection(_ result: KeyboardSessionSnapshot) -> some View {
    Section {
      Text("iosApp.keyboardPendingResult")
        .foregroundStyle(.primary)
      Text(result.text ?? "")
        .lineLimit(6)
        .textSelection(.enabled)
        .accessibilityIdentifier("pendingKeyboardResult")
      Button {
        UIPasteboard.general.string = result.text
        copiedPendingID = result.id
      } label: {
        Label(
          copiedPendingID == result.id ? "iosApp.copied" : "iosApp.copy",
          systemImage: copiedPendingID == result.id ? "checkmark" : "doc.on.doc")
      }
      .buttonStyle(.bordered)
      .tint(.primary)
      .accessibilityIdentifier("copyPendingKeyboardResult")
      Button("iosApp.keyboardKeepPendingResult") {
        let cleared = controller.dismissPendingResult(id: result.id)
        pendingActionFailed = !cleared
        if cleared,
          viewModel.errorKey == "iosApp.keyboardPendingResult"
            || viewModel.errorKey == "iosApp.keyboardUnavailable"
        {
          viewModel.errorKey = nil
        }
      }
      .buttonStyle(.bordered)
      .tint(.primary)
      .accessibilityIdentifier("keepPendingKeyboardResult")
      if pendingActionFailed {
        Text("iosApp.keyboardPendingActionFailed").foregroundStyle(.red)
      }
    } header: {
      Text("iosApp.keyboardPendingResultTitle")
    }
  }
}
