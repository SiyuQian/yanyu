import SwiftData
import SwiftUI
import UIKit

struct KeyboardSetupView: View {
  @Environment(DictationViewModel.self) private var viewModel
  @Environment(\.modelContext) private var modelContext
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.openURL) private var openURL
  let controller: KeyboardDictationController

  var body: some View {
    Form {
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
              if scenePhase != .active { controller.cancel(viewModel: viewModel) }
            }
          }
          .accessibilityIdentifier("keyboardStartRecording")
          .disabled(
            !viewModel.isModelLoaded || viewModel.state == .recording
              || viewModel.state == .requestingPermission || viewModel.state == .transcribing
              || viewModel.hasDiscardablePendingAudio || viewModel.hasPendingTranscriptSave
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
}
