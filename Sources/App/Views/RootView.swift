import SwiftUI

struct RootView: View {
    @EnvironmentObject var store: ProcessStore
    @EnvironmentObject var appDelegate: AppDelegate

    var body: some View {
        TabView {
            NavigationView {
                ProcessListView()
            }
            .navigationViewStyle(StackNavigationViewStyle())
            .tabItem { Label("Reports", systemImage: "list.bullet.rectangle") }

            NavigationView {
                SettingsView()
            }
            .navigationViewStyle(StackNavigationViewStyle())
            .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .onAppear { store.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            store.refresh()
        }
        .onReceive(appDelegate.$openLogPath) { path in
            if let path { store.pendingLogPath = path }
        }
    }
}

struct GlassBackground<S: Shape>: ViewModifier {
    var shape: S
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}
