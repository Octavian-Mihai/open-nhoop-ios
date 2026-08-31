import Foundation

// MARK: - Local JSON caches
// WhoopStore has no workout table and DailyMetric has no `steps` field. These
// tiny Application Support files sit next to whoop.sqlite.

enum LocalJSONCaches {
    static func file(_ name: String) throws -> URL {
        let fm = FileManager.default
        let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                              appropriateFor: nil, create: true)
            .appendingPathComponent("OpenWhoop", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent(name)
    }
}

// MARK: - Workouts

enum LocalWorkoutStore {
    private static let fileName = "local-workouts.json"

    private struct FilePayload: Codable {
        var byDevice: [String: [CodableWorkout]]
    }

    private struct CodableWorkout: Codable {
        var id: String
        var deviceId: String
        var startTs: Int
        var endTs: Int
        var avgHr: Double
        var peakHr: Int
        var strain: Double?
        var kind: String?
        var durationS: Int
        var zoneTimePct: [String: Double]
        var avgHrrPct: Double?
        var hrmax: Double?
        var hrmaxSource: String
        var caloriesKcal: Double?
        var caloriesKj: Double?

        init(_ w: Workout) {
            id = w.id; deviceId = w.deviceId
            startTs = w.startTs; endTs = w.endTs
            avgHr = w.avgHr; peakHr = w.peakHr
            strain = w.strain; kind = w.kind; durationS = w.durationS
            zoneTimePct = Dictionary(uniqueKeysWithValues: w.zoneTimePct.map { (String($0.key), $0.value) })
            avgHrrPct = w.avgHrrPct; hrmax = w.hrmax
            hrmaxSource = w.hrmaxSource
            caloriesKcal = w.caloriesKcal; caloriesKj = w.caloriesKj
        }

        func asWorkout() -> Workout {
            var zones: [Int: Double] = [:]
            for (k, v) in zoneTimePct {
                if let z = Int(k) { zones[z] = v }
            }
            return Workout(
                id: id, deviceId: deviceId, startTs: startTs, endTs: endTs,
                avgHr: avgHr, peakHr: peakHr, strain: strain, kind: kind,
                durationS: durationS, zoneTimePct: zones, avgHrrPct: avgHrrPct,
                hrmax: hrmax, hrmaxSource: hrmaxSource,
                caloriesKcal: caloriesKcal, caloriesKj: caloriesKj)
        }
    }

    static func replace(deviceId: String, day: String, workouts: [Workout]) {
        var payload = loadPayload()
        var existing = payload.byDevice[deviceId] ?? []
        existing.removeAll { SleepDetection.utcDayString(from: Double($0.startTs)) == day }
        existing.append(contentsOf: workouts.map { CodableWorkout($0) })
        existing.sort { $0.startTs < $1.startTs }
        payload.byDevice[deviceId] = existing
        savePayload(payload)
    }

    static func workouts(deviceId: String, from: String, to: String) -> [Workout] {
        let rows = loadPayload().byDevice[deviceId] ?? []
        return rows.compactMap { row in
            let day = SleepDetection.utcDayString(from: Double(row.startTs))
            guard day >= from, day <= to else { return nil }
            return row.asWorkout()
        }.reversed()
    }

    private static func loadPayload() -> FilePayload {
        guard let url = try? LocalJSONCaches.file(fileName),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(FilePayload.self, from: data) else {
            return FilePayload(byDevice: [:])
        }
        return decoded
    }

    private static func savePayload(_ payload: FilePayload) {
        guard let url = try? LocalJSONCaches.file(fileName),
              let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Test seam: wipe the on-disk cache.
    static func resetForTests() {
        if let url = try? LocalJSONCaches.file(fileName) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

// MARK: - Daily extras (steps)

struct DailyExtras: Codable, Equatable {
    var steps: Int?
}

enum LocalDailyExtrasStore {
    private static let fileName = "local-daily-extras.json"

    private struct FilePayload: Codable {
        var byDevice: [String: [String: DailyExtras]]   // device → day → extras
    }

    static func steps(deviceId: String, day: String) -> Int? {
        loadPayload().byDevice[deviceId]?[day]?.steps
    }

    static func setSteps(deviceId: String, day: String, steps: Int) {
        var payload = loadPayload()
        var days = payload.byDevice[deviceId] ?? [:]
        var extras = days[day] ?? DailyExtras()
        extras.steps = steps
        days[day] = extras
        payload.byDevice[deviceId] = days
        savePayload(payload)
    }

    private static func loadPayload() -> FilePayload {
        guard let url = try? LocalJSONCaches.file(fileName),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(FilePayload.self, from: data) else {
            return FilePayload(byDevice: [:])
        }
        return decoded
    }

    private static func savePayload(_ payload: FilePayload) {
        guard let url = try? LocalJSONCaches.file(fileName),
              let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func resetForTests() {
        if let url = try? LocalJSONCaches.file(fileName) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
