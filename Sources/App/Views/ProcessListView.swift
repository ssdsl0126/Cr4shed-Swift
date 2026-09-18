import SwiftUI

struct ProcessListView: View {
    @EnvironmentObject var store: ProcessStore

    var body: some View {
        List {
            ForEach(store.processes) { proc in
                NavigationLink(destination: LogListView(process: proc)) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(proc.name).font(.headline)
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
