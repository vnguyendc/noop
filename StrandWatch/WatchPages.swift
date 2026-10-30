import SwiftUI

/// Page 1: today's scores. Charge leads; Effort and Rest sit beside it.
struct WatchTodayPage: View {
    let snapshot: WatchSnapshot?
    /// Why the last workout ended, or why workouts are unavailable.
    let notice: String?

    private var s: CGFloat { WatchLayout.scale }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WatchLayout.pt(10)) {
                HStack(alignment: .center, spacing: WatchLayout.pt(8)) {
                    VStack(spacing: 2) {
                        WatchScoreRing(name: "Charge", value: snapshot?.recovery,
                                       color: snapshot?.recovery.map(WatchScoreColor.charge) ?? .secondary,
                                       diameter: WatchLayout.pt(94), lineWidth: WatchLayout.pt(7.5),
                                       fontSize: WatchLayout.pt(31))
                        Text("Charge")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(snapshot?.recovery == nil ? .secondary : .primary)
                    }
                    VStack(alignment: .leading, spacing: WatchLayout.pt(9)) {
                        smallRing("Effort", snapshot?.effort, snapshot?.effort.map(WatchScoreColor.effort) ?? .secondary)
                        smallRing("Rest", snapshot?.rest, WatchScoreColor.rest)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 2)

                if let snapshot {
                    HStack(spacing: WatchLayout.pt(12)) {
                        Label(snapshot.bpm.map { "\($0) bpm" } ?? "–", systemImage: "heart.fill")
                            .foregroundStyle(.primary)
                            .accessibilityLabel(snapshot.bpm.map { "Heart rate \($0) beats per minute" } ?? "No heart rate")
                        Label(snapshot.batteryPct.map { "\($0)%" } ?? "–", systemImage: batterySymbol(snapshot.batteryPct))
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(snapshot.batteryPct.map { "Strap battery \($0) percent" } ?? "Strap battery unknown")
                    }
                    .font(.footnote)
                    .monospacedDigit()
                    Text(snapshot.updatedText())
                        .font(.caption2)
                        .foregroundStyle(snapshot.isStale() ? .orange : .secondary)
                } else {
                    Text("Open NOOP on your iPhone to sync.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let notice {
                    Text(notice)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle { Text("Today").foregroundStyle(Color.noopAccent) }
    }

    private func smallRing(_ name: String, _ value: Int?, _ color: Color) -> some View {
        HStack(spacing: WatchLayout.pt(6)) {
            WatchScoreRing(name: name, value: value, color: color,
                           diameter: WatchLayout.pt(38), lineWidth: WatchLayout.pt(4.5),
                           fontSize: WatchLayout.pt(13))
            Text(name)
                .font(.system(size: WatchLayout.pt(15), weight: .medium))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(value == nil ? .secondary : .primary)
        }
    }
}

/// Page 2: the numbers behind the scores.
struct WatchVitalsPage: View {
    let snapshot: WatchSnapshot?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WatchLayout.pt(10)) {
                vital("HRV", color: WatchScoreColor.rest,
                      value: snapshot?.hrvMs.map(String.init), unit: "ms",
                      spoken: snapshot?.hrvMs.map { "HRV \($0) milliseconds" })
                vital("Resting heart rate", color: WatchScoreColor.rose,
                      value: snapshot?.restingHr.map(String.init), unit: "bpm",
                      spoken: snapshot?.restingHr.map { "Resting heart rate \($0) beats per minute" })
                sleep
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
        .navigationTitle { Text("Vitals").foregroundStyle(Color.noopAccent) }
    }

    private func vital(_ name: String, color: Color, value: String?, unit: String, spoken: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(name)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(color)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value ?? "–")
                    .font(.system(size: WatchLayout.pt(29), weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(value == nil ? Color.secondary : Color.primary)
                if value != nil {
                    Text(unit)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken ?? "\(name) not available")
    }

    private var sleep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Sleep")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(WatchScoreColor.cyan)
            if let minutes = snapshot?.sleepMin {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(minutes / 60)")
                        .font(.system(size: WatchLayout.pt(29), weight: .semibold, design: .rounded))
                    Text("h")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("\(minutes % 60)")
                        .font(.system(size: WatchLayout.pt(29), weight: .semibold, design: .rounded))
                        .padding(.leading, 4)
                    Text("m")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .monospacedDigit()
            } else {
                Text("–")
                    .font(.system(size: WatchLayout.pt(29), weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(snapshot?.sleepMin.map { "Sleep \($0 / 60) hours \($0 % 60) minutes" } ?? "Sleep not available")
    }
}

/// Page 3: pick a type to start a workout. The last type used is listed first.
struct WatchWorkoutsPage: View {
    let lastUsed: WatchWorkoutKind?
    let start: (WatchWorkoutKind) -> Void

    var body: some View {
        List {
            ForEach(WatchWorkoutKind.ordered(lastUsed: lastUsed), id: \.self) { kind in
                Button {
                    start(kind)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: kind.systemImage)
                            .font(.body.weight(.medium))
                            .foregroundStyle(Color.noopAccent)
                            .frame(width: 30, height: 30)
                            .background(Color.noopAccentMuted, in: Circle())
                        VStack(alignment: .leading, spacing: 0) {
                            Text(kind.name)
                                .lineLimit(2)
                                .minimumScaleFactor(0.85)
                            if kind == lastUsed {
                                Text("Last used")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .accessibilityLabel(kind == lastUsed ? "Start \(kind.name), last used" : "Start \(kind.name)")
            }
        }
        .navigationTitle { Text("Start a workout").foregroundStyle(Color.noopAccent) }
    }
}

/// Shown after the user ends a workout, until tapped or after a few seconds.
struct WatchSavedWorkoutView: View {
    let saved: WatchLiveModel.SavedWorkout
    let dismiss: () -> Void

    static let showFor: TimeInterval = 8

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WatchLayout.pt(8)) {
                Image(systemName: "checkmark")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Color.noopAccent)
                    .frame(width: 34, height: 34)
                    .background(Color.noopAccentMuted, in: Circle())
                    .accessibilityHidden(true)
                Text(saved.kind.name)
                    .font(.headline)
                HStack(spacing: 12) {
                    Text(durationText)
                        .monospacedDigit()
                        .accessibilityLabel("Duration \(durationText)")
                    Label("avg \(saved.avgHr)", systemImage: "heart.fill")
                        .monospacedDigit()
                        .accessibilityLabel("Average heart rate \(saved.avgHr) beats per minute")
                }
                .font(.footnote)
                Text("Your Effort score will be on your iPhone.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
        .navigationTitle { Text("Workout saved").foregroundStyle(Color.noopAccent) }
        .contentShape(Rectangle())
        .onTapGesture(perform: dismiss)
        .task {
            try? await Task.sleep(nanoseconds: UInt64(Self.showFor * 1_000_000_000))
            if !Task.isCancelled { dismiss() }
        }
    }

    private var durationText: String {
        let seconds = max(0, Int(saved.end.timeIntervalSince(saved.start)))
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

func batterySymbol(_ pct: Int?) -> String {
    guard let pct else { return "battery.0percent" }
    switch pct {
    case ..<13: return "battery.0percent"
    case ..<38: return "battery.25percent"
    case ..<63: return "battery.50percent"
    case ..<88: return "battery.75percent"
    default: return "battery.100percent"
    }
}

extension Color {
    /// StrandPalette.accentMuted (#10271F), the dark-green tint behind accent icons.
    static let noopAccentMuted = Color(red: 0x10 / 255, green: 0x27 / 255, blue: 0x1F / 255)
}
