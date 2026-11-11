import SwiftUI

#if DEBUG
/// A panel on the bundled sample data (Tue Nov 10, 2026, 9:15 am), for Xcode's canvas.
/// No token and no network: everything comes from the JSON fixtures in `Resources/`.
///
/// Without Xcode, the same views can be drawn to a PNG instead:
/// `NotionBar --snapshot out.png --state tasks --dark`
struct PreviewPanel: View {
    var state = "default"
    @ViewState private var scene: Snapshot.Scene?

    var body: some View {
        Group {
            if let scene {
                PanelCard()
                    .environmentObject(scene.store)
                    .environmentObject(scene.model)
                    .environmentObject(scene.settings)
                    .environmentObject(scene.focus)
                    .modifier(PreviewTheme(settings: scene.settings))
            } else {
                ProgressView()
            }
        }
        .padding(24)
        .frame(width: Metrics.panelWidth + 48)
        .task { scene = await Snapshot.scene(state: state) }
    }
}

private struct PreviewTheme: ViewModifier {
    var settings: AppSettings

    func body(content: Content) -> some View {
        Themed { content }.environmentObject(settings)
    }
}

struct Panel_Previews: PreviewProvider {
    static var previews: some View {
        PreviewPanel(state: "default").previewDisplayName("Panel")
        PreviewPanel(state: "default").preferredColorScheme(.dark).previewDisplayName("Panel, dark")
        PreviewPanel(state: "tasks").previewDisplayName("tasks/ open")
        PreviewPanel(state: "option").previewDisplayName("⌥ held")
        PreviewPanel(state: "filter").previewDisplayName("Filtering")
        PreviewPanel(state: "add").previewDisplayName("Adding a task")
        PreviewPanel(state: "offline").previewDisplayName("Offline")
        PreviewPanel(state: "error").previewDisplayName("Bad token")
        PreviewPanel(state: "empty").previewDisplayName("Everything done")
    }
}

struct StatusIcon_Previews: PreviewProvider {
    static var previews: some View {
        HStack(spacing: 16) {
            icon("checklist", "2")
            icon("exclamationmark.circle", "5")
            icon("exclamationmark.circle.fill", "5", Tint.red)
            icon("checkmark.circle", "")
            icon("checkmark.circle.fill", "4", Tint.green)
            icon("hourglass", "5")
            icon("exclamationmark.triangle", "")
        }
        .padding()
        .previewDisplayName("Menu bar icon")
    }

    private static func icon(_ symbol: String, _ text: String, _ tint: Color? = nil) -> some View {
        let model = StatusIconModel()
        model.symbol = symbol
        model.text = text
        model.tint = tint
        return StatusIconView(model: model)
    }
}
#endif
