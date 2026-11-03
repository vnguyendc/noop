import Foundation
import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// The body stats scoring needs, read once from `ProfileStore` so the scoring itself stays pure.
struct ScoringProfile: Equatable {
    var hrMax: Int
    var sex: String
    var weightKg: Double
    var heightCm: Double
    var age: Int

    init(hrMax: Int, sex: String, weightKg: Double, heightCm: Double, age: Int) {
        self.hrMax = hrMax
        self.sex = sex
        self.weightKg = weightKg
        self.heightCm = heightCm
        self.age = age
    }

    @MainActor
    init(_ profile: ProfileStore) {
        self.init(hrMax: profile.hrMax, sex: profile.sex, weightKg: profile.weightKg,
                  heightCm: profile.heightCm, age: profile.age)
    }
}

/// One scoring path for every workout the user tracks themselves: the phone's own Start/End and a
/// workout started on the watch. Both produce a `source: "manual"` row under the chosen sport.
enum WorkoutScoring {
    /// A workout needs at least this many HR samples to be worth saving.
    static let minSamples = 2

    /// Scores the samples and builds the row to save, or nil when there is too little data (the
    /// strap never streamed HR). Samples are expected in time order.
    static func row(samples: [HRSample], start: Date, end: Date, sport: String,
                    profile: ScoringProfile) -> WorkoutRow? {
        guard samples.count >= minSamples else { return nil }
        let bpms = samples.map(\.bpm)
        let avg = Int((Double(bpms.reduce(0, +)) / Double(bpms.count)).rounded())
        let peak = bpms.max() ?? 0
        let strain = StrainScorer.strain(samples, maxHR: Double(profile.hrMax), sex: profile.sex)
        // Estimate calories from the HR window (same Keytel/Harris–Benedict model the auto-detector
        // uses) so a tracked session shows energy too, not just duration/strain. (#117)
        let up = UserProfile(weightKg: profile.weightKg, heightCm: profile.heightCm,
                             age: Double(profile.age), sex: profile.sex)
        let kcal = Calories.estimateBoutCalories(samples, profile: up, hrmax: Double(profile.hrMax),
                                                 restingHR: nil).0
        return WorkoutRow(
            startTs: Int(start.timeIntervalSince1970), endTs: Int(end.timeIntervalSince1970),
            sport: sport, source: "manual", durationS: end.timeIntervalSince(start),
            energyKcal: kcal > 0 ? kcal : nil, avgHr: avg, maxHr: peak, strain: strain,
            distanceM: nil, zonesJSON: nil, notes: nil)
    }
}

/// The scores and vitals the watch shows, picked from the cached days the way the phone's Charge
/// glance already does: the latest day that has each value.
struct WatchScoreValues: Equatable {
    var charge: Int?
    var effort: Int?
    var rest: Int?
    var hrvMs: Int?
    var restingHr: Int?
    var sleepMin: Int?

    init(charge: Int? = nil, effort: Int? = nil, rest: Int? = nil, hrvMs: Int? = nil,
         restingHr: Int? = nil, sleepMin: Int? = nil) {
        self.charge = charge
        self.effort = effort
        self.rest = rest
        self.hrvMs = hrvMs
        self.restingHr = restingHr
        self.sleepMin = sleepMin
    }

    /// `days` in ascending date order, as `Repository.days` is kept.
    init(days: [DailyMetric]) {
        func latest<T>(_ value: (DailyMetric) -> T?) -> T? {
            days.last(where: { value($0) != nil }).flatMap(value)
        }
        charge = latest(\.recovery).map { Int($0.rounded()) }
        effort = latest(\.strain).map { Int($0.rounded()) }
        rest = latest { AnalyticsEngine.Rest.composite(daily: $0) }.map { Int($0.rounded()) }
        hrvMs = latest(\.avgHrv).map { Int($0.rounded()) }
        restingHr = latest(\.restingHr)
        sleepMin = latest(\.totalSleepMin).map { Int($0.rounded()) }
    }
}
