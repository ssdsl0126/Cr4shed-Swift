import SwiftUI

struct LogListView: View {
    @EnvironmentObject var store: ProcessStore
    @ObservedObject var process: CrashProcess

    var body: some View {
        List {
            ForEach(process.logs.sorted { $0.date > $1.date }) { log in
                NavigationLink(destination: LogInfoView(log: log)) {
                    Text((CR4StringFromDate(log.date, .pretty) as String?) ?? log.dateName)
                }
            }
            .onDelete { indexSet in
                let sorted = process.logs.sorted { $0.date > $1.date }
                for index in indexSet {
                    try? FileManager.default.removeItem(atPath: sorted[index].path)
                }
                store.refresh()
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle(process.name)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Clear") {
                    process.deleteAllLogs()
                    store.refresh()
                }
            }
        }
        .refreshable { store.refresh() }
    }
}

struct PadLogListView: View {
    @EnvironmentObject private var store: ProcessStore

    let process: CrashProcess?
    @Binding var selectedLogPath: String?
    let showsSidebarButton: Bool
    let onShowSidebar: () -> Void
    let onDelete: (IndexSet) -> Void

    private var sortedLogs: [CrashLog] {
        process?.logs.sorted { $0.date > $1.date } ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if let process, !process.logs.isEmpty {
                List {
                    ForEach(sortedLogs) { log in
                        Button {
                            selectedLogPath = log.path
                        } label: {
                            PadLogRow(log: log)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(
                            selectedLogPath == log.path
                                ? Color.accentColor.opacity(0.13)
                                : Color(uiColor: .secondarySystemGroupedBackground)
                        )
                    }
                    .onDelete(perform: onDelete)
                }
                .listStyle(.plain)
                .refreshable { store.refresh() }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary)
                    Text("Select a Process")
                        .font(.headline)
                    Text("Choose a process to view its crash records.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private var header: some View {
        HStack(spacing: 12) {
            if showsSidebarButton {
                Button(action: onShowSidebar) {
                    Image(systemName: "sidebar.left")
                        .font(.title3)
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel(Text("Show Sidebar"))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Crash Records")
                    .font(.title2.bold())
                Text(process?.name ?? String(localized: "No Process Selected"))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .layoutPriority(1)

            Spacer(minLength: 4)

            Menu {
                Button(role: .destructive) {
                    process?.deleteAllLogs()
                    store.refresh()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.headline)
                    .frame(width: 36, height: 36)
            }
            .disabled(process == nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
    }
}

private struct PadLogRow: View {
    let log: CrashLog

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text(dateText)
                    .font(.headline)
                if let exception = log.exceptionTypeText {
                    Text(exception)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Text(log.culpritText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .layoutPriority(1)

            Spacer(minLength: 6)

            Image(systemName: "chevron.forward")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary.opacity(0.6))
        }
        .contentShape(Rectangle())
        .padding(.vertical, 8)
    }

    private var dateText: String {
        (CR4StringFromDate(log.date, .pretty) as String?) ?? log.dateName
    }
}
