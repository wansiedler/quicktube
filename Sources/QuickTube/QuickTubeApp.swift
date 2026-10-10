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
                Image(systemName: model.state.phase.symbolName)
            }
        }
        Settings {
            SettingsView(model: model)
        }
    }
}
