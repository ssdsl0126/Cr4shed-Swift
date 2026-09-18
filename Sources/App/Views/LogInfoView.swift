import SwiftUI

struct LogInfoView: View {
    let log: CrashLog
    @State private var shareError = false

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(log.processName).font(.title2.weight(.semibold))
                        Text((log.info["ProcessBundleID"] as? String) ?? "").foregroundColor(.secondary)
                    }
                    .padding(.vertical, 8)
                }
                Section {
                    HStack {
                        Text("Crash Date")
                        Spacer()
                        Text((CR4StringFromDate(log.date, .pretty) as String?) ?? String(localized: "N/A"))
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Culprit")
                        Spacer()
                        Text(culpritText)
                            .foregroundColor(.secondary)
                    }
                    if let reason = log.info["NSExceptionReason"] as? String, !reason.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Reason")
                            Text(reason).font(.footnote).foregroundColor(.secondary)
                        }
                    }
                }
            }
            .listStyle(InsetGroupedListStyle())

            NavigationLink(destination: LogViewer(log: log)) {
                Text("View Log")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .foregroundColor(.white)
                    .background(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .padding()
        }
        .navigationTitle((CR4StringFromDate(log.date, .timeOnly) as String?) ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    share()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .alert("Export Failed", isPresented: $shareError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Log file does not exist.")
        }
    }

    private var culpritText: String {
        let raw = (log.info["Culprit"] as? String) ?? ""
        if raw.isEmpty || raw == "Unknown" {
            return String(localized: "Unknown")
        }
        return raw
    }

    private func share() {
        guard FileManager.default.fileExists(atPath: log.path) else {
            shareError = true
            return
        }
        FileShare.present(url: URL(fileURLWithPath: log.path))
    }
}
