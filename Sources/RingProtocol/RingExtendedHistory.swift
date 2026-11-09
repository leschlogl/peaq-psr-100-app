import Foundation

public enum RingSleepStage: Int, Codable, CaseIterable, Sendable {
    case awake = 0, light = 1, deep = 2
    public var title: String { switch self { case .awake: return "Awake"; case .light: return "Light"; case .deep: return "Deep" } }
}
public struct RingSleepSegment: Equatable, Codable, Sendable {
    public let start: Date
    public let end: Date
    public let stage: RingSleepStage
    public var duration: TimeInterval { end.timeIntervalSince(start) }
    public init(start: Date, end: Date, stage: RingSleepStage) { self.start = start; self.end = end; self.stage = stage }
}
public struct RingWorkout: Equatable, Codable, Sendable {
    public let start: Date
    public let end: Date
    public let typeCode: Int?
    public let steps: Int
    public let calories: Double
    public let distanceMetres: Double?
    public let averageHeartRate: Int?
    public init(start: Date, end: Date, typeCode: Int?, steps: Int, calories: Double, distanceMetres: Double?, averageHeartRate: Int?) {
        self.start = start; self.end = end; self.typeCode = typeCode; self.steps = steps
        self.calories = calories; self.distanceMetres = distanceMetres; self.averageHeartRate = averageHeartRate
    }
}

/// Decodes sleep transitions and exercise summaries from ring history.
public enum RingExtendedHistory {
    private static func calendar(_ zone: TimeZone) -> Calendar {
        var result = Calendar(identifier: .gregorian); result.timeZone = zone; return result
    }
    private static func date(_ bytes: [UInt8], calendar: Calendar) -> Date? {
        guard bytes.count == 6 else { return nil }
        let r = bytes.map(Int.init)
        guard (20...40).contains(r[0]), (1...12).contains(r[1]), (1...31).contains(r[2]), r[3] < 24, r[4] < 60, r[5] < 60 else { return nil }
        let c = DateComponents(year: 2000+r[0], month: r[1], day: r[2], hour: r[3], minute: r[4], second: r[5])
        guard let date = calendar.date(from: c) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard back.year == c.year, back.month == c.month, back.day == c.day, back.hour == c.hour,
              back.minute == c.minute, back.second == c.second else { return nil }
        return date
    }
    /// 0A/A2: calendar date, then stage/hour/minute transition triples.
    /// Hours before 19:00 belong to the following calendar day.
    /// The final transition closes the previous stage; no end is invented for it.
    public static func sleep(_ block: RingHistoryBlock, now: Date = Date(), timeZone: TimeZone = .current) -> [RingSleepSegment] {
        guard block.command == 0x0a, block.subcommand == 0xa2 else { return [] }
        let b = [UInt8](block.payload)
        guard b.count >= 9, (b.count - 3) % 3 == 0 else { return [] }
        let cal = calendar(timeZone)
        guard let base = date(Array(b[0..<3]) + [0, 0, 0], calendar: cal),
              let next = cal.date(byAdding: .day, value: 1, to: base) else { return [] }
        var points: [(Date, RingSleepStage?)] = []
        for offset in stride(from: 3, to: b.count, by: 3) {
            let mode = b[offset], hour = Int(b[offset+1]), minute = Int(b[offset+2])
            // Energy/breathing summary triples aren't sleep transitions.
            if mode == 0xff || mode == 0xfe { continue }
            guard hour < 24, minute < 60,
                  let stamp = cal.date(bySettingHour: hour, minute: minute, second: 0, of: hour >= 19 ? base : next),
                  stamp <= now.addingTimeInterval(300) else { return [] }
            if let previous = points.last, stamp <= previous.0 { return [] }
            points.append((stamp, RingSleepStage(rawValue: Int(mode))))
        }
        guard points.count >= 2 else { return [] }
        var result: [RingSleepSegment] = []
        for index in 0..<(points.count - 1) {
            let start = points[index].0, end = points[index+1].0
            guard end.timeIntervalSince(start) <= 18*3600 else { return [] }
            if let stage = points[index].1 { result.append(RingSleepSegment(start: start, end: end, stage: stage)) }
        }
        return result
    }
    /// 0A/A5 supports 16-byte legacy records and 49-byte summaries.
    /// Other record sizes are skipped.
    public static func workouts(_ block: RingHistoryBlock, now: Date = Date(), timeZone: TimeZone = .current) -> [RingWorkout] {
        guard block.command == 0x0a, block.subcommand == 0xa5, !block.payload.isEmpty else { return [] }
        let b = [UInt8](block.payload), cal = calendar(timeZone)
        let size: Int
        if b.count % 49 == 0 { size = 49 }
        else if b.count % 16 == 0 { size = 16 }
        else { return [] }
        func be(_ i: Int) -> UInt32 { b[i..<i+4].reduce(0) { ($0 << 8) | UInt32($1) } }
        var result: [RingWorkout] = []
        for offset in stride(from: 0, to: b.count, by: size) {
            let start: Date, end: Date, steps: Int, calories: Double, type: Int?, distance: Double?, hr: Int?
            if size == 49 {
                guard let stamp = date(Array(b[offset+1..<offset+7]), calendar: cal) else { continue }
                let seconds = Double(be(offset+7))
                guard seconds > 0, seconds <= 24*3600 else { continue }
                start = stamp; end = stamp.addingTimeInterval(seconds)
                type = Int(b[offset]); steps = Int(be(offset+11)); calories = Double(be(offset+15))
                distance = Double(be(offset+19)); hr = b[offset+24] == 0 ? nil : Int(b[offset+24])
            } else {
                guard let stamp = date(Array(b[offset..<offset+3]) + [b[offset+3], b[offset+4], 0], calendar: cal),
                      b[offset+5] < 24, b[offset+6] < 60,
                      var finish = cal.date(bySettingHour: Int(b[offset+5]), minute: Int(b[offset+6]), second: 0, of: stamp) else { continue }
                if finish < stamp { finish = cal.date(byAdding: .day, value: 1, to: finish)! }
                guard finish > stamp, finish.timeIntervalSince(stamp) <= 24*3600 else { continue }
                start = stamp; end = finish; type = nil
                steps = Int(be(offset+8))
                let bits = b[offset+12..<offset+16].enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << (8 * $1.offset)) }
                calories = Double(Float(bitPattern: bits)); distance = nil; hr = nil
            }
            guard end <= now.addingTimeInterval(300), RingMetric.steps.accepts(Double(steps)), RingMetric.calories.accepts(calories),
                  distance.map({ $0 <= 1_000_000 }) ?? true, hr.map({ (25...240).contains($0) }) ?? true else { continue }
            result.append(RingWorkout(start: start, end: end, typeCode: type, steps: steps, calories: calories, distanceMetres: distance, averageHeartRate: hr))
        }
        return result
    }
}
