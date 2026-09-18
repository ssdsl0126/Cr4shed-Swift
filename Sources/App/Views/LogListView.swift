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
