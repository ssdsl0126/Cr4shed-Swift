import SwiftUI

struct LogViewer: View {
    let log: CrashLog
    @State private var shareError = false
    @State private var content: String = ""

    var body: some View {
        Group {
            if content.isEmpty {
                ProgressView()
            } else {
                FastTextView(text: content)
            }
        }
        .onAppear {
            DispatchQueue.global(qos: .userInitiated).async {
                let text = log.contents
                DispatchQueue.main.async {
                    self.content = text
                }
            }
        }
        .navigationTitle(log.dateName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    guard FileManager.default.fileExists(atPath: log.path) else {
                        shareError = true
                        return
                    }
                    FileShare.present(url: URL(fileURLWithPath: log.path))
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
}
