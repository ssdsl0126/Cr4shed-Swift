import SwiftUI

struct BlacklistView: View {
    @State private var items: [String] = (CR4PrefsBlacklist() as? [String]) ?? []

    var body: some View {
        List {
            ForEach(items.indices, id: \.self) { index in
                TextField("Process name (Case-sensitive)", text: binding(index))
                    .onSubmit { persist() }
            }
            .onDelete { offsets in
                items.remove(atOffsets: offsets)
                persist()
            }
        }
        .navigationTitle("Blacklist")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    items.append("")
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .onAppear {
            items = (CR4PrefsBlacklist() as? [String]) ?? []
        }
    }

    private func binding(_ index: Int) -> Binding<String> {
        Binding(
            get: { items.indices.contains(index) ? items[index] : "" },
            set: { newValue in
                if items.indices.contains(index) {
                    items[index] = newValue
                    persist()
                }
            }
        )
    }

    private func persist() {
        CR4PrefsSetObject(items as NSArray, kProcessBlacklist)
        NotificationCenter.default.post(name: Notification.Name(CR4BlacklistDidChangeNotificationName as String), object: nil)
    }
}
