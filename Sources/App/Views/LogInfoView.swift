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
                    if let excType = exceptionTypeText, !excType.isEmpty {
                        HStack {
                            Text("Exception")
                            Spacer()
                            Text(excType)
                                .foregroundColor(.secondary)
                        }
                    }
                    HStack {
                        Text("Culprit")
                        Spacer()
                        Text(culpritText)
                            .foregroundColor(.secondary)
                    }
                    if let reason = reasonText, !reason.isEmpty {
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
        .alert(String(localized: "Export Failed"), isPresented: $shareError) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(String(localized: "Log file does not exist."))
        }
    }

    private var culpritText: String {
        let raw = (log.info["Culprit"] as? String) ?? ""
        if raw.isEmpty || raw == "Unknown" {
            return String(localized: "Unknown")
        }
        return raw
    }

    private var exceptionTypeText: String? {
        if let t = log.info["ExceptionType"] as? String, !t.isEmpty { return t }
        for line in log.contents.components(separatedBy: "\n") {
            if line.hasPrefix("Exception type: ") {
                let t = String(line.dropFirst("Exception type: ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return t }
            }
        }
        return nil
    }

    private var reasonText: String? {
        if let r = log.info["NSExceptionReason"] as? String, !r.isEmpty { return r }
        if let r = log.info["CrashReason"] as? String, !r.isEmpty { return r }
        if let r = log.info["Reason"] as? String, !r.isEmpty { return r }
        for line in log.contents.components(separatedBy: "\n") {
            if line.hasPrefix("Reason: ") {
                let r = String(line.dropFirst("Reason: ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !r.isEmpty { return r }
            }
            if line.hasPrefix("Swift Error Message: ") {
                let r = String(line.dropFirst("Swift Error Message: ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !r.isEmpty { return r }
            }
            if line.hasPrefix("Exception subtype: ") {
                let r = String(line.dropFirst("Exception subtype: ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !r.isEmpty { return r }
            }
        }
        return nil
    }

    private func share() {
        guard FileManager.default.fileExists(atPath: log.path) else {
            shareError = true
            return
        }
        FileShare.present(url: URL(fileURLWithPath: log.path))
    }
}

