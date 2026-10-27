import SwiftData
import SwiftUI

@main
struct YanyuApp: App {
  @State private var dictationViewModel = DictationViewModel()
  @State private var transcriptContainer: ModelContainer?
  @AppStorage("yanyu.ios.appearance") private var appearance = AppearancePreference.system.rawValue

  init() {
    do {
      _transcriptContainer = State(initialValue: try TranscriptStore.makeContainer())
    } catch {
      _transcriptContainer = State(initialValue: nil)
    }
  }

  var body: some Scene {
    WindowGroup {
      Group {
        if let transcriptContainer {
          ContentView()
            .environment(dictationViewModel)
            .modelContainer(transcriptContainer)
        } else {
          ContentUnavailableView(
            "iosApp.historyUnavailable",
            systemImage: "externaldrive.badge.exclamationmark",
            description: Text("iosApp.historyUnavailableBody")
          )
        }
      }
      .preferredColorScheme(AppearancePreference.resolve(appearance).preferredColorScheme)
    }
  }
}
