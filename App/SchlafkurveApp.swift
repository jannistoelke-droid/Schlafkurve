import SleepEngineCore
import SwiftUI

@main
struct SchlafkurveApp: App {
    @State private var controller = SessionController.shared
    @State private var store = SessionStore.shared
    @State private var player = ClipPlayer.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(controller)
                .environment(store)
                .environment(player)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

enum Theme {
    static let background = Color(red: 0.043, green: 0.063, blue: 0.125)
    static let surface = Color(red: 0.078, green: 0.102, blue: 0.180)
    static let elevated = Color(red: 0.110, green: 0.141, blue: 0.251)
    static let secondaryText = Color(red: 0.604, green: 0.643, blue: 0.761)
    static let accent = Color(red: 0.533, green: 0.596, blue: 1.0)

    static func color(_ stage: SleepStage) -> Color {
        switch stage {
        case .wake: return Color(red: 1.0, green: 0.541, blue: 0.396)
        case .rem: return Color(red: 0.702, green: 0.533, blue: 1.0)
        case .light: return Color(red: 0.392, green: 0.710, blue: 0.965)
        case .deep: return Color(red: 0.224, green: 0.286, blue: 0.671)
        }
    }

    static func color(_ group: SoundGroup) -> Color {
        switch group {
        case .snore: return Color(red: 1.0, green: 0.655, blue: 0.149)
        case .talk: return Color(red: 0.149, green: 0.776, blue: 0.855)
        case .cough: return Color(red: 0.941, green: 0.384, blue: 0.573)
        case .environment: return Color(red: 0.565, green: 0.643, blue: 0.682)
        case .loud: return Color(red: 1.0, green: 0.933, blue: 0.345)
        }
    }
}

struct Card<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title).font(.headline).foregroundStyle(Theme.secondaryText)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct RootView: View {
    @Environment(SessionController.self) private var controller
    @Environment(SessionStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            Tab("Wecker", systemImage: "alarm", value: 0) { SetupView() }
            Tab("Nächte", systemImage: "moon.stars", value: 1) { HistoryView() }
            Tab("Statistik", systemImage: "chart.bar", value: 2) { StatsView() }
            Tab("Einstellungen", systemImage: "gearshape", value: 3) { SettingsView() }
        }
        .fullScreenCover(isPresented: Binding(get: { controller.phase != .idle }, set: { _ in })) {
            NightView()
        }
        .sheet(isPresented: Binding(get: { controller.pendingReportID != nil && controller.phase == .idle },
                                    set: { if !$0 { controller.pendingReportID = nil } })) {
            if let id = controller.pendingReportID {
                NavigationStack {
                    ReportView(sessionID: id)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Fertig") { controller.pendingReportID = nil }
                            }
                        }
                }
            }
        }
        .task { await controller.launch() }
        .onChange(of: scenePhase) { _, newPhase in
            controller.scenePhaseChanged(active: newPhase == .active)
            if newPhase == .active { store.reload() }
        }
    }
}
