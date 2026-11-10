import QuickTubeCore
import SwiftUI

@main
struct QuickTubeApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            if case .uploading(let progress) = model.state.phase {
                Label("\(Int(progress * 100))%", systemImage: model.state.phase.symbolName)
            } else {
                MenuBarIcon.image(for: model.state.phase)
            }
        }
        Settings {
            SettingsView(model: model)
        }
        .windowResizability(.contentMinSize)
        Window("History", id: HistoryView.windowID) {
            HistoryView(model: model)
        }
        .defaultSize(width: 640, height: 480)
        .windowResizability(.contentMinSize)
        // Opened only from "Show All…"; a menu bar app shows no window at launch.
        .defaultLaunchBehavior(.suppressed)
    }
}
