import WidgetKit
import SwiftUI

struct NOOPWatchEntry: TimelineEntry {
    let date: Date
    /// nil until the watch has synced once; the views show dashes rather than sample numbers.
    let snapshot: WatchSnapshot?
}

struct NOOPWatchProvider: TimelineProvider {
    func placeholder(in context: Context) -> NOOPWatchEntry {
        NOOPWatchEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (NOOPWatchEntry) -> Void) {
        let snapshot = context.isPreview ? .placeholder : WatchSnapshot.loadForWatch()
        completion(NOOPWatchEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NOOPWatchEntry>) -> Void) {
        let snapshot = WatchSnapshot.loadForWatch()
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        completion(Timeline(entries: [NOOPWatchEntry(date: Date(), snapshot: snapshot)], policy: .after(next)))
    }
}

struct NOOPWatchWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NOOPWatchEntry

    private var snapshot: WatchSnapshot? { entry.snapshot }

    var body: some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: Double(snapshot?.recovery ?? 0), in: 0...100) {
                Image(systemName: "bolt.heart.fill")
            } currentValueLabel: {
                Text(snapshot?.recovery.map(String.init) ?? "–")
            }
            .gaugeStyle(.accessoryCircular)
            .tint(recoveryColor)
        case .accessoryInline:
            Text(inlineText)
        default:
            VStack(alignment: .leading, spacing: 2) {
                Text("Charge \(snapshot?.recovery.map(String.init) ?? "–")")
                    .font(.headline)
                    .foregroundStyle(recoveryColor)
                Text("\(snapshot?.bpm.map(String.init) ?? "–") bpm")
                    .font(.caption)
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusText: String {
        guard let snapshot else { return "Not synced yet" }
        if snapshot.isStale() { return snapshot.updatedText() }
        return snapshot.bonded ? "Strap connected" : "Strap offline"
    }

    private var inlineText: String {
        var parts: [String] = []
        if let recovery = snapshot?.recovery { parts.append("Charge \(recovery)") }
        if let bpm = snapshot?.bpm { parts.append("\(bpm) bpm") }
        return parts.isEmpty ? "NOOP" : parts.joined(separator: ", ")
    }

    private var recoveryColor: Color {
        guard let recovery = snapshot?.recovery else { return .secondary }
        return recovery >= 67 ? .green : recovery >= 34 ? .yellow : .red
    }
}

struct NOOPWatchWidget: Widget {
    let kind = "NOOPWatchWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NOOPWatchProvider()) { entry in
            NOOPWatchWidgetView(entry: entry)
                .containerBackground(.black, for: .widget)
        }
        .configurationDisplayName("NOOP Charge")
        .description("Charge, heart rate, and strap state from your iPhone.")
        .supportedFamilies([.accessoryCircular, .accessoryInline, .accessoryRectangular])
    }
}
