//
//  DebugPaneView.swift
//  ConjureDSPExportAUTemplateExtension
//
//  Default-hidden debug pane for the exported AU. Shows plugin identity,
//  live render statistics, and a scrolling event log. Accessed via the gear
//  menu in ExportAUMainView.
//

import SwiftUI

/// Static plugin identity + init-time facts, captured once when the AU loads.
struct PluginInfo: Sendable {
    var presetName: String
    var language: String
    var subtype: String
    var manufacturer: String
    var bundlePath: String
    var runtimeConfigFound: Bool
    var paramCount: Int
    var latencySamples: UInt32
    var pythonHome: String?
    var namModelFile: String?

    static let empty = PluginInfo(
        presetName: "",
        language: "",
        subtype: "",
        manufacturer: "",
        bundlePath: "",
        runtimeConfigFound: false,
        paramCount: 0,
        latencySamples: 0,
        pythonHome: nil,
        namModelFile: nil
    )
}

@MainActor
struct DebugPaneView: View {
    @ObservedObject var debugLog: ExportDebugLog
    let stats: RenderStats.Snapshot
    let info: PluginInfo

    @State private var infoExpanded = true
    @State private var statsExpanded = true
    @State private var logExpanded = true
    @State private var copyButtonLabel = "Copy Log"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Debug")
                    .font(.caption).bold()
                Spacer()
                Button(copyButtonLabel) {
                    let text = debugLog.formattedForCopy()
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copyButtonLabel = "Copied"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        copyButtonLabel = "Copy Log"
                    }
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(.secondary)

                Button("Clear") {
                    debugLog.clear()
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    infoSection
                    statsSection
                    logSection
                }
                .padding(8)
            }
            .frame(height: 300)
            .background(Color.black.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 8)
        }
    }

    // MARK: - Plugin Info

    private var infoSection: some View {
        DisclosureGroup(isExpanded: $infoExpanded) {
            VStack(alignment: .leading, spacing: 2) {
                infoRow("Preset", info.presetName)
                infoRow("Language", info.language)
                infoRow("AU", "\(info.manufacturer)/\(info.subtype)")
                infoRow("Params", "\(info.paramCount)")
                infoRow("Latency", "\(info.latencySamples) samples")
                infoRow("Config loaded", info.runtimeConfigFound ? "yes" : "no")
                if let py = info.pythonHome {
                    infoRow("Python home", py)
                }
                if let nam = info.namModelFile {
                    infoRow("NAM model", nam)
                }
                infoRow("Bundle", info.bundlePath)
            }
            .padding(.top, 4)
        } label: {
            Text("Plugin Info").font(.caption).bold()
        }
    }

    @ViewBuilder
    private func infoRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(key)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.caption2.monospaced())
                .textSelection(.enabled)
                .lineLimit(2)
        }
    }

    // MARK: - Live Stats

    private var statsSection: some View {
        DisclosureGroup(isExpanded: $statsExpanded) {
            VStack(alignment: .leading, spacing: 2) {
                infoRow("Render calls", "\(stats.renderCallCount)")
                infoRow("Calls/sec", String(format: "%.1f", stats.callsPerSecond))
                infoRow("Total frames", "\(stats.totalFrames)")
                infoRow("Last frames", "\(stats.lastFrameCount)")
                infoRow("Sample rate", String(format: "%.0f Hz", stats.sampleRate))
                infoRow("Last render", formatDuration(stats.lastRenderDurationNs))
                infoRow("Peak render", formatDuration(stats.peakRenderDurationNs))
                infoRow("Last CPU", String(format: "%.1f %%", stats.lastCpuPercent))
                infoRow("Peak CPU", String(format: "%.1f %%", stats.peakCpuPercent))
                infoRow("Dropouts", "\(stats.dropoutCount)")
            }
            .padding(.top, 4)
        } label: {
            Text("Live Stats").font(.caption).bold()
        }
    }

    private func formatDuration(_ ns: UInt64) -> String {
        if ns == 0 { return "—" }
        if ns < 1_000 { return "\(ns) ns" }
        if ns < 1_000_000 { return String(format: "%.2f µs", Double(ns) / 1_000) }
        return String(format: "%.2f ms", Double(ns) / 1_000_000)
    }

    // MARK: - Event Log

    private var logSection: some View {
        DisclosureGroup(isExpanded: $logExpanded) {
            ScrollViewReader { proxy in
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(debugLog.entries) { entry in
                        logRow(entry)
                            .id(entry.id)
                    }
                }
                .onChange(of: debugLog.entries.last?.id) { _, newId in
                    if let id = newId {
                        withAnimation(nil) {
                            proxy.scrollTo(id, anchor: .bottom)
                        }
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            Text("Event Log (\(debugLog.entries.count))").font(.caption).bold()
        }
    }

    @ViewBuilder
    private func logRow(_ entry: ExportDebugLog.Entry) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text(levelTag(entry.level))
                .font(.caption2.monospaced())
                .foregroundStyle(levelColor(entry.level))
                .frame(width: 46, alignment: .leading)
            Text("[\(entry.category)]")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            Text(entry.message)
                .font(.caption2.monospaced())
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func levelTag(_ level: ExportDebugLog.Level) -> String {
        switch level {
        case .debug:   return "DEBUG"
        case .info:    return "INFO"
        case .warning: return "WARN"
        case .error:   return "ERROR"
        }
    }

    private func levelColor(_ level: ExportDebugLog.Level) -> Color {
        switch level {
        case .debug:   return .gray
        case .info:    return .primary
        case .warning: return .orange
        case .error:   return .red
        }
    }
}
