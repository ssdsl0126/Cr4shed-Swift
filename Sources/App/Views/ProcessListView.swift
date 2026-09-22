import SwiftUI

struct ProcessListView: View {
    @EnvironmentObject var store: ProcessStore

    var body: some View {
        List {
            ForEach(store.processes) { proc in
                NavigationLink(destination: LogListView(process: proc)) {
                    HStack {
                        ProcessIcon(image: proc.appIcon)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(proc.name)
                                .font(.headline)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .layoutPriority(1)
                            Text(dateText(proc.latestDate)).font(.subheadline).foregroundColor(.secondary)
                        }
                        Spacer()
                        Text("\(proc.logs.count)")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.red)
                            .clipShape(Capsule())
                    }
                    .padding(.vertical, 4)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        proc.deleteAllLogs()
                        store.refresh()
                    } label: { Label("Delete", systemImage: "trash") }
                    Button {
                        if proc.isBlacklisted { proc.removeFromBlacklist() }
                        else { proc.addToBlacklist() }
                    } label: {
                        Label(proc.isBlacklisted ? "Un-blacklist" : "Blacklist", systemImage: "nosign")
                    }
                    .tint(.blue)
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle("Cr4shed")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Clear") {
                    store.processes.forEach { $0.deleteAllLogs() }
                    store.refresh()
                }
            }
        }
        .refreshable { store.refresh() }
        .background(NavigationLink(
            destination: pendingDestination,
            isActive: Binding(
                get: { store.pendingLogPath != nil },
                set: { if !$0 { store.pendingLogPath = nil } }
            ),
            label: { EmptyView() }
        ))
    }

    @ViewBuilder
    private var pendingDestination: some View {
        if let path = store.pendingLogPath {
            LogInfoView(log: CrashLog(path: path))
        } else {
            EmptyView()
        }
    }

    private func dateText(_ date: Date?) -> String {
        guard let date else { return "" }
        return (CR4StringFromDate(date, .pretty) as String?) ?? ""
    }
}

struct ProcessIcon: View {
    let image: UIImage?
    var size: CGFloat = 40

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.2)
                    .foregroundColor(.secondary)
                    .background(Color.secondary.opacity(0.12))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
        .accessibilityHidden(true)
    }
}

struct PadProcessSidebar: View {
    @EnvironmentObject private var store: ProcessStore

    @Binding var selectedSection: RootSection
    @Binding var selectedProcessID: String?
    let showsProcesses: Bool
    let onSelectProcess: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                Text("Cr4shed")
                    .font(.largeTitle.bold())
                Spacer()
                if showsProcesses {
                    Button("Clear") {
                        store.processes.forEach { $0.deleteAllLogs() }
                        store.refresh()
                    }
                    .buttonStyle(.bordered)
                    .disabled(store.processes.isEmpty)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Picker("Section", selection: $selectedSection) {
                Text("Reports").tag(RootSection.reports)
                Text("Settings").tag(RootSection.settings)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.bottom, 14)

            if showsProcesses {
                processList
            } else {
                Spacer(minLength: 0)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private var processList: some View {
        List {
            ForEach(store.processes) { process in
                Button {
                    selectedProcessID = process.id
                    onSelectProcess()
                } label: {
                    PadProcessRow(process: process)
                }
                .buttonStyle(.plain)
                .listRowBackground(
                    selectedProcessID == process.id
                        ? Color.accentColor.opacity(0.13)
                        : Color(uiColor: .secondarySystemGroupedBackground)
                )
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        process.deleteAllLogs()
                        store.refresh()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        if process.isBlacklisted {
                            process.removeFromBlacklist()
                        } else {
                            process.addToBlacklist()
                        }
                    } label: {
                        Label(
                            process.isBlacklisted ? "Un-blacklist" : "Blacklist",
                            systemImage: "nosign"
                        )
                    }
                    .tint(.blue)
                }
            }
        }
        .listStyle(.plain)
        .refreshable { store.refresh() }
    }
}

private struct PadProcessRow: View {
    let process: CrashProcess

    var body: some View {
        HStack(spacing: 12) {
            ProcessIcon(image: process.appIcon, size: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(process.name)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(dateText(process.latestDate))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            Text("\(process.logs.count)")
                .font(.caption.weight(.semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.red)
                .clipShape(Capsule())

            Image(systemName: "chevron.forward")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary.opacity(0.6))
        }
        .contentShape(Rectangle())
        .padding(.vertical, 7)
    }

    private func dateText(_ date: Date?) -> String {
        guard let date else { return "" }
        return (CR4StringFromDate(date, .pretty) as String?) ?? ""
    }
}
