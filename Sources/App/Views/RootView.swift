import SwiftUI

enum RootSection: Hashable {
    case reports
    case settings
}

enum LogDetailMode: Hashable {
    case overview
    case rawLog
}

struct RootView: View {
    @EnvironmentObject private var store: ProcessStore
    @EnvironmentObject private var appDelegate: AppDelegate
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var selectedSection: RootSection = .reports
    @State private var selectedProcessID: String?
    @State private var selectedLogPath: String?
    @State private var detailMode: LogDetailMode = .overview

    var body: some View {
        GeometryReader { geometry in
            if horizontalSizeClass == .regular && geometry.size.width >= 700 {
                PadRootView(
                    availableSize: geometry.size,
                    selectedSection: $selectedSection,
                    selectedProcessID: $selectedProcessID,
                    selectedLogPath: $selectedLogPath,
                    detailMode: $detailMode
                )
            } else {
                CompactRootView()
            }
        }
        .onAppear {
            store.refresh()
            synchronizeSelection()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            store.refresh()
        }
        .onReceive(store.$processes) { _ in
            synchronizeSelection()
        }
        .onReceive(appDelegate.$openLogPath) { path in
            guard let path else { return }
            store.pendingLogPath = path
            selectLog(at: path)
        }
    }

    private func synchronizeSelection() {
        guard !store.processes.isEmpty else {
            selectedProcessID = nil
            selectedLogPath = nil
            return
        }

        if let pendingPath = store.pendingLogPath,
           store.processes.contains(where: { process in
               process.logs.contains(where: { $0.path == pendingPath })
           }) {
            selectLog(at: pendingPath)
            return
        }

        let process = store.processes.first(where: { $0.id == selectedProcessID })
            ?? store.processes[0]
        selectedProcessID = process.id

        if !process.logs.contains(where: { $0.path == selectedLogPath }) {
            selectedLogPath = process.logs.max(by: { $0.date < $1.date })?.path
            detailMode = .overview
        }
    }

    private func selectLog(at path: String) {
        guard let process = store.processes.first(where: { process in
            process.logs.contains(where: { $0.path == path })
        }) else { return }
        selectedSection = .reports
        selectedProcessID = process.id
        selectedLogPath = path
        detailMode = .overview
        store.pendingLogPath = nil
    }
}

private struct CompactRootView: View {
    @EnvironmentObject private var store: ProcessStore

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
    }
}

private struct PadRootView: View {
    @EnvironmentObject private var store: ProcessStore

    let availableSize: CGSize
    @Binding var selectedSection: RootSection
    @Binding var selectedProcessID: String?
    @Binding var selectedLogPath: String?
    @Binding var detailMode: LogDetailMode

    @State private var showsProcessOverlay = false

    private var usesThreeColumns: Bool { availableSize.width >= 1180 }
    private var processColumnWidth: CGFloat {
        min(max(availableSize.width * 0.25, 300), 340)
    }
    private var recordColumnWidth: CGFloat {
        min(max(availableSize.width * 0.33, 320), 360)
    }

    private var selectedProcess: CrashProcess? {
        store.processes.first(where: { $0.id == selectedProcessID })
    }

    private var selectedLog: CrashLog? {
        selectedProcess?.logs.first(where: { $0.path == selectedLogPath })
    }

    var body: some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                if usesThreeColumns {
                    processSidebar
                        .frame(width: processColumnWidth)
                    Divider()
                }

                switch selectedSection {
                case .reports:
                    PadLogListView(
                        process: selectedProcess,
                        selectedLogPath: $selectedLogPath,
                        showsSidebarButton: !usesThreeColumns,
                        onShowSidebar: showProcessOverlay,
                        onDelete: deleteLogs
                    )
                    .frame(width: recordColumnWidth)

                    Divider()

                    PadLogDetailView(log: selectedLog, mode: $detailMode)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .settings:
                    PadSettingsContainer(
                        showsSidebarButton: !usesThreeColumns,
                        onShowSidebar: showProcessOverlay
                    )
                }
            }

            if !usesThreeColumns && showsProcessOverlay {
                overlaySidebar
                    .transition(.move(edge: .leading))
                    .zIndex(2)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .animation(.easeInOut(duration: 0.22), value: showsProcessOverlay)
        .onChange(of: selectedSection) { _ in
            showsProcessOverlay = false
        }
        .onChange(of: selectedProcessID) { _ in
            guard let process = selectedProcess else {
                selectedLogPath = nil
                return
            }
            selectedLogPath = process.logs.max(by: { $0.date < $1.date })?.path
            detailMode = .overview
            showsProcessOverlay = false
        }
        .onChange(of: selectedLogPath) { _ in
            detailMode = .overview
        }
    }

    private var processSidebar: some View {
        PadProcessSidebar(
            selectedSection: $selectedSection,
            selectedProcessID: $selectedProcessID,
            showsProcesses: selectedSection == .reports,
            onSelectProcess: { showsProcessOverlay = false }
        )
    }

    private var overlaySidebar: some View {
        HStack(spacing: 0) {
            processSidebar
                .frame(width: min(360, availableSize.width * 0.72))
                .background(Color(uiColor: .systemGroupedBackground))
                .shadow(color: .black.opacity(0.18), radius: 24, x: 8)

            Color.black.opacity(0.12)
                .contentShape(Rectangle())
                .onTapGesture { showsProcessOverlay = false }
        }
    }

    private func showProcessOverlay() {
        showsProcessOverlay = true
    }

    private func deleteLogs(at offsets: IndexSet) {
        guard let process = selectedProcess else { return }
        let sortedLogs = process.logs.sorted { $0.date > $1.date }
        for index in offsets where sortedLogs.indices.contains(index) {
            try? FileManager.default.removeItem(atPath: sortedLogs[index].path)
        }
        store.refresh()
    }
}

private struct PadSettingsContainer: View {
    let showsSidebarButton: Bool
    let onShowSidebar: () -> Void

    var body: some View {
        NavigationView {
            SettingsView()
                .toolbar {
                    if showsSidebarButton {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button(action: onShowSidebar) {
                                Image(systemName: "sidebar.left")
                            }
                            .accessibilityLabel(Text("Show Sidebar"))
                        }
                    }
                }
        }
        .navigationViewStyle(StackNavigationViewStyle())
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
