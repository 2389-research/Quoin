import AppKit
import SwiftUI
import QuoinRender

/// The custom About window (Quoin ▸ About Quoin). More context than the
/// standard panel: what Quoin is, the engines inside it, and where the
/// pieces live.
struct AboutView: View {

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if let build, build != short { return "Version \(short) (\(build))" }
        return "Version \(short)"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)

            VStack(spacing: 3) {
                Text("Quoin")
                    .quoinScaledFont(size: 24, weight: .bold, design: .rounded)
                Text(version)
                    .quoinScaledFont(size: 11)
                    .foregroundStyle(.secondary)
            }

            Text("A native WYSIWYG markdown editor.\nPlain files on disk — no lock-in, no cloud, no JavaScript.")
                .quoinScaledFont(size: 12)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Divider()
                .frame(width: 260)

            VStack(alignment: .leading, spacing: 6) {
                engineRow("Markdown", "swift-markdown (cmark-gfm), byte-lossless round-trip")
                engineRow("Diagrams", "MermaidKit — native Mermaid, all 30 diagram types")
                engineRow("Math", "Vinculum — native LaTeX typesetting, no web view")
                engineRow("Text", "TextKit 2, SF Pro Rounded")
            }
            .quoinScaledFont(size: 11)

            Divider()
                .frame(width: 260)

            VStack(spacing: 4) {
                HStack(spacing: 14) {
                    Link("MermaidKit", destination: URL(string: "https://github.com/2389-research/MermaidKit")!)
                    Link("Vinculum", destination: URL(string: "https://github.com/2389-research/Vinculum")!)
                    Button("Acknowledgements") { isAcknowledgementsVisible = true }
                        .buttonStyle(.link)
                }
                .quoinScaledFont(size: 11)
                Text("© 2026 2389 Research · Chicago, Illinois")
                    .quoinScaledFont(size: 10.5)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 36)
        .padding(.top, 24)
        .padding(.bottom, 20)
        .frame(width: 360)
        .fixedSize()
        // Apache 2.0 requires shipping the attribution (launch ledger L11).
        .sheet(isPresented: $isAcknowledgementsVisible) {
            VStack(spacing: 0) {
                ScrollView {
                    Text(acknowledgementsText)
                        .quoinScaledFont(size: 11, design: .monospaced)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                Divider()
                HStack {
                    Spacer()
                    Button("Done") { isAcknowledgementsVisible = false }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(10)
            }
            .frame(width: 480, height: 420)
        }
    }

    @State private var isAcknowledgementsVisible = false

    private var acknowledgementsText: String {
        let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "md")
            ?? Bundle.main.url(forResource: "Acknowledgements", withExtension: "md", subdirectory: "Resources")
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "swift-markdown © Apple Inc., Apache License 2.0 — https://github.com/swiftlang/swift-markdown\nMermaidKit © 2026 2389 Research — https://github.com/2389-research/MermaidKit\nVinculum © 2026 2389 Research — https://github.com/2389-research/Vinculum"
        }
        return text
    }

    private func engineRow(_ label: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .fontWeight(.semibold)
                .frame(width: 72, alignment: .trailing)
                .foregroundStyle(.secondary)
            Text(detail)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
