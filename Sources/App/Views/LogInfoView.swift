import SwiftUI
import UIKit

struct LogInfoView: View {
    let log: CrashLog
    @State private var shareError = false

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        ProcessIcon(image: AppIconResolver.icon(for: log), size: 52)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(log.processName).font(.title2.weight(.semibold))
                            Text(log.bundleIdentifier)
                                .foregroundColor(.secondary)
                        }
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
                    if let excType = log.exceptionTypeText, !excType.isEmpty {
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
                        Text(log.culpritText)
                            .foregroundColor(.secondary)
                    }
                    if let reason = log.reasonText, !reason.isEmpty {
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

    private func share() {
        guard FileManager.default.fileExists(atPath: log.path) else {
            shareError = true
            return
        }
        FileShare.present(url: URL(fileURLWithPath: log.path))
    }
}

struct PadLogDetailView: View {
    let log: CrashLog?
    @Binding var mode: LogDetailMode

    @State private var shareError = false
    @State private var rawContent = ""
    @State private var wrapsLines = true

    var body: some View {
        VStack(spacing: 0) {
            header

            if let log {
                VStack(spacing: 16) {
                    identityCard(for: log)

                    Picker("Log Display", selection: $mode) {
                        Text("Overview").tag(LogDetailMode.overview)
                        Text("Raw Log").tag(LogDetailMode.rawLog)
                    }
                    .pickerStyle(.segmented)

                    switch mode {
                    case .overview:
                        overview(for: log)
                    case .rawLog:
                        rawLogCard(for: log)
                    }
                }
                .padding(20)
            } else {
                emptyState
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .onAppear { loadRawContent() }
        .onChange(of: log?.path) { _ in
            loadRawContent()
        }
        .alert(String(localized: "Export Failed"), isPresented: $shareError) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(String(localized: "Log file does not exist."))
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(mode == .overview ? "Crash Details" : "Detailed Log"))
                    .font(.title2.bold())
                if let log {
                    Text((CR4StringFromDate(log.date, .pretty) as String?) ?? log.dateName)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Button(action: share) {
                Image(systemName: "square.and.arrow.up")
                    .font(.title3)
                    .frame(width: 36, height: 36)
            }
            .disabled(log == nil)
            .accessibilityLabel(Text("Share"))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
    }

    private func identityCard(for log: CrashLog) -> some View {
        HStack(spacing: 16) {
            ProcessIcon(image: AppIconResolver.icon(for: log), size: 60)

            VStack(alignment: .leading, spacing: 5) {
                Text(log.processName)
                    .font(.title3.bold())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(log.bundleIdentifier)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                if let applicationName = AppIconResolver.applicationName(for: log) {
                    Text("\(String(localized: "Host App")): \(applicationName)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 0)
        }
        .padding(18)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }

    private func overview(for log: CrashLog) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                PadDetailCard(title: "Crash Overview") {
                    DetailValueRow(
                        title: "Crash Date",
                        value: (CR4StringFromDate(log.date, .pretty) as String?) ?? String(localized: "N/A")
                    )
                    Divider()
                    DetailValueRow(
                        title: "Exception",
                        value: log.exceptionTypeText ?? String(localized: "N/A")
                    )
                    Divider()
                    DetailValueRow(title: "Culprit", value: log.culpritText)
                }

                PadDetailCard(title: "Reason") {
                    Text(log.reasonText ?? String(localized: "N/A"))
                        .font(.body)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)

                    Button {
                        mode = .rawLog
                    } label: {
                        Label("View Log", systemImage: "doc.text.magnifyingglass")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, 8)
                }
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
    }

    private func rawLogCard(for log: CrashLog) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("\(log.processName).log")
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Spacer()

                Button {
                    UIPasteboard.general.string = rawContent
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .accessibilityLabel(Text("Copy Log"))

                Button {
                    wrapsLines.toggle()
                } label: {
                    Image(systemName: wrapsLines ? "text.justify" : "arrow.left.and.right.text.vertical")
                }
                .accessibilityLabel(Text("Toggle Line Wrap"))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if rawContent.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                FastTextView(text: rawContent, wrapsLines: wrapsLines)
            }
        }
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 42))
                .foregroundColor(.secondary)
            Text("Select a Crash Report")
                .font(.title3.bold())
            Text("Choose a crash record to view its details.")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadRawContent() {
        rawContent = ""
        guard let log else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let contents = log.contents
            DispatchQueue.main.async {
                guard self.log?.path == log.path else { return }
                rawContent = contents
            }
        }
    }

    private func share() {
        guard let log, FileManager.default.fileExists(atPath: log.path) else {
            shareError = true
            return
        }
        FileShare.present(url: URL(fileURLWithPath: log.path))
    }
}

private struct PadDetailCard<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title3.bold())
            Divider()
            content()
        }
        .padding(18)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }
}

private struct DetailValueRow: View {
    let title: LocalizedStringKey
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title)
            Spacer(minLength: 12)
            Text(value)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}
