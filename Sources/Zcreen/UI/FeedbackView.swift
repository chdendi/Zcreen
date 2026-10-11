import SwiftUI
import AppKit

final class FeedbackController: NSObject, ObservableObject, NSSharingServiceDelegate {
    static let shared = FeedbackController()
    @Published var descriptionText = ""
    @Published var includeLogs = true
    @Published private(set) var isPreparing = false
    @Published private(set) var message = ""
    @Published private(set) var report: FeedbackReport?
    private var window: NSWindow?
    private var sharingService: NSSharingService?

    func present() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 440),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Zcreen Feedback"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: FeedbackView(controller: self))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func createDraft() {
        guard !isPreparing else { return }
        isPreparing = true
        message = ""
        report = nil
        let description = descriptionText
        let logs = includeLogs
        let builder = FeedbackReportBuilder(logsDirectory: FileLogSink.shared.directoryURL,
            outputDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("ZcreenFeedback"),
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString)
        FileLogSink.shared.flush {
            do {
                let report = try builder.build(description: description, includeLogs: logs)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.report = report
                    self.isPreparing = false
                    let items: [Any] = [report.body, report.archive]
                    guard let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: items) else {
                        self.message = "No compatible mail app is available. Open the package below and send it manually, or configure a mail account."
                        return
                    }
                    service.recipients = [FeedbackReport.recipient]
                    service.subject = report.subject
                    service.delegate = self
                    self.sharingService = service
                    service.perform(withItems: items)
                    self.message = "Email draft opened. Review the attachment and click Send in your mail app."
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.isPreparing = false
                    self?.message = "Could not create feedback: \(error.localizedDescription)"
                }
            }
        }
    }

    func dismiss() { window?.close() }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.message = "Could not open the mail draft. Open the package below and send it manually."
            self?.sharingService = nil
        }
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        self.sharingService = nil
    }
}

struct FeedbackView: View {
    @ObservedObject var controller: FeedbackController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Send Feedback").font(.title2.weight(.semibold))
            Text("To: \(FeedbackReport.recipient)").foregroundStyle(.secondary)
            Text("What happened? Include what you expected and how to reproduce it.").font(.callout)
            TextEditor(text: $controller.descriptionText)
                .font(.body)
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.secondary.opacity(0.3)))
                .accessibilityLabel("Feedback description")
                .disabled(controller.isPreparing)
            Toggle("Attach recent Zcreen logs (up to 2 days, 4 MB)", isOn: $controller.includeLogs)
                .disabled(controller.isPreparing)
            Text("Logs may contain app names and window titles. Confirmation creates a local email draft; review it before sending.")
                .font(.caption).foregroundStyle(.secondary)
            if !controller.message.isEmpty {
                Text(controller.message).font(.callout).textSelection(.enabled)
            }
            HStack {
                if let report = controller.report {
                    Button("Open Package") { NSWorkspace.shared.activateFileViewerSelecting([report.archive]) }
                }
                Spacer()
                Button("Cancel") { controller.dismiss() }.keyboardShortcut(.cancelAction)
                if controller.isPreparing { ProgressView().controlSize(.small) }
                Button("Create Email Draft") { controller.createDraft() }
                    .disabled(controller.isPreparing || controller.descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
