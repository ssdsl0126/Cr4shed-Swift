import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: ProcessStore
    @State private var sorting = CR4PrefsSortingMethod() as String? ?? "Date"
    @State private var jetsam = CR4PrefsEnableJetsam()
    @State private var extensionCheckInTimeouts = CR4PrefsRecordExtensionCheckInTimeouts()

    var body: some View {
        List {
            Section("General") {
                Picker("Process sorting method", selection: $sorting) {
                    Text("Date").tag("Date")
                    Text("Name").tag("Name")
                }
                .onChange(of: sorting) { value in
                    CR4PrefsSetObject(value as NSString, kSortingMethod)
                    store.refresh()
                }
                NavigationLink("Process blacklist") { BlacklistView() }
                Toggle("Log Jetsam Events", isOn: $jetsam)
                    .onChange(of: jetsam) { value in
                        CR4PrefsSetObject(NSNumber(value: value), kEnableJetsam)
                    }
                Toggle("Log Extension Check-in Timeouts", isOn: $extensionCheckInTimeouts)
                    .onChange(of: extensionCheckInTimeouts) { value in
                        CR4PrefsSetObject(NSNumber(value: value), kRecordExtensionCheckInTimeouts)
                    }
            }
            Section("Credits") {
                Link("Follow @Muirey03 on Twitter", destination: URL(string: "https://twitter.com/Muirey03")!)
                Link("Donate to help development", destination: URL(string: "https://paypal.me/Muirey03Dev")!)
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle("Settings")
    }
}
