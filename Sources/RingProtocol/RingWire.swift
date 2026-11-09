import Foundation

public struct RingGATTProfile: Equatable {
    public let service: String
    public let write: String
    public let notify: String
}

public enum RingWire {
    // Confirmed by GATT discovery on the user's PSR 100 through Core Bluetooth.
    public static let service = "4CDABAA0-2CEA-C0C1-B38D-A0481AE60A97"
    public static let write = "4CDABAA1-2CEA-C0C1-B38D-A0481AE60A97"
    public static let notify = "4CDABAA2-2CEA-C0C1-B38D-A0481AE60A97"
    public static let applicationProfiles = [
        RingGATTProfile(service: service, write: write, notify: notify),
        RingGATTProfile(service: "1AE60A97-A048-B38D-C9C3-EA4CA0B8DA4C",
                        write: "1AE60A97-A048-B38D-C9C3-EA4CA1B8DA4C",
                        notify: "1AE60A97-A048-B38D-C9C3-EA4CA2B8DA4C")
    ]
    public static let advertisedService = "BAA0"
    public static func crc(_ bytes: [UInt8]) -> UInt16 {
        var result: UInt16 = 0xffff
        for byte in bytes {
            result ^= UInt16(byte) << 8
            for _ in 0..<8 { result = result & 0x8000 != 0 ? (result &<< 1) ^ 0x1021 : result &<< 1 }
        }
        return result
    }
    public static func frame(kind: UInt8 = 0x21, sequence: UInt16, payload: [UInt8]) -> Data {
        precondition(payload.count <= 65535)
        let checksum = crc(payload)
        return Data([0xba, kind, UInt8(payload.count >> 8), UInt8(payload.count & 255),
                     UInt8(checksum >> 8), UInt8(checksum & 255),
                     UInt8(sequence >> 8), UInt8(sequence & 255)] + payload)
    }
    public static func batteryQuery(sequence: UInt16 = 0x70) -> Data {
        frame(sequence: sequence, payload: [4, 0, 0x40, 0, 0])
    }
    /// Requests device identity without binding credentials.
    public static func deviceIdentityQuery(sequence: UInt16 = 0x71) -> Data {
        frame(sequence: sequence, payload: [0x83, 0, 0x40, 0, 0])
    }
    public enum CommandError: Error { case invalidToken }
    public static func historyCommands(token: String, now: Date = Date(), timeZone: TimeZone = .current) throws -> [Data] {
        let bytes = Array(token.utf8)
        guard (1...64).contains(bytes.count), bytes.allSatisfy({ (33...126).contains($0) }) else {
            throw CommandError.invalidToken
        }
        var commands = [
            frame(kind: 0x20, sequence: 3, payload: [0x83, 0, 1, 0, UInt8(bytes.count + 1)] + bytes + [1]),
            frame(sequence: 4, payload: [4, 0, 0x44, 0, UInt8(bytes.count + 1)] + bytes + [0])
        ]
        commands += historyQueries(now: now, timeZone: timeZone)
        return commands
    }
    /// Initial queries and history requests only; no session, clock, or profile writes.
    /// Useful for checking whether a ring's existing session permits history access.
    public static func historyQueries(now: Date = Date(), timeZone: TimeZone = .current) -> [Data] {
        var commands: [Data] = [batteryQuery()]
        // Only the observed initial queries and history requests. No clock/profile/config writes.
        for (seq, payload): (UInt16, [UInt8]) in [
            (5, [2, 0, 0x40, 0, 0]), (6, [1, 0, 0x14, 0, 0]), (7, [1, 0, 0x12, 0, 0]),
            (0x14, [0x0a, 0, 0xa6, 0, 1, 3])
        ] { commands.append(frame(sequence: seq, payload: payload)) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: now)
        let previous = calendar.date(byAdding: .day, value: -1, to: start)!
        // Request all observed selectors for yesterday and today; mappings remain experimental.
        var seq: UInt16 = 0x30
        for date in [previous, start] {
            let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            let stamp = [c.year! % 100, c.month!, c.day!, c.hour!, c.minute!, c.second!].map(UInt8.init)
            for selector: UInt8 in [1, 0x0d, 0x0e, 3, 2, 7, 8, 0x0a, 0x0f, 0x0b, 0x0c, 4] {
                commands.append(frame(sequence: seq, payload: [0x0a, 0, 0xa0, 0, 8, selector] + stamp + [1]))
                seq += 1
            }
        }
        return commands
    }
}

public struct RingHistoryBlock: Codable, Equatable {
    public let command: UInt8
    public let subcommand: UInt8
    public let payload: Data
    public let receivedAt: Date
    public init(command: UInt8, subcommand: UInt8, payload: Data, receivedAt: Date) {
        self.command = command; self.subcommand = subcommand; self.payload = payload; self.receivedAt = receivedAt
    }
}

/// Bounded stream + protocol-fragment assembly. Rejects bad CRCs and truncated inner payloads.
public struct RingDecoder {
    private var stream: [UInt8] = []
    private struct Key: Hashable { let sequence: UInt16; let command: UInt8; let sub: UInt8 }
    private struct Fragment { var data: [UInt8]; var time: Date }
    private var fragments: [Key: Fragment] = [:]
    public private(set) var rejectedFrames = 0
    public private(set) var batteryStatus: RingBatteryStatus?
    public private(set) var firmwareVersion: String?
    public private(set) var bluetoothAddress: String?
    public private(set) var identityResponseDescription: String?
    public private(set) var receivedBlocks: [RingHistoryBlock] = []
    public init() {}
    public mutating func reset() { stream.removeAll(); fragments.removeAll(); receivedBlocks.removeAll(); batteryStatus = nil; firmwareVersion = nil; bluetoothAddress = nil; identityResponseDescription = nil }

    public mutating func ingest(_ data: Data, now: Date = Date(), timeZone: TimeZone = .current) -> [RingReading] {
        batteryStatus = nil
        firmwareVersion = nil; bluetoothAddress = nil; identityResponseDescription = nil
        receivedBlocks.removeAll(keepingCapacity: true)
        fragments = fragments.filter { now.timeIntervalSince($0.value.time) < 30 }
        stream.append(contentsOf: data)
        guard stream.count <= 65_536 else { stream.removeAll(); rejectedFrames += 1; return [] }
        var readings: [RingReading] = []
        while !stream.isEmpty {
            guard let start = stream.firstIndex(of: 0xba) else { stream.removeAll(); break }
            if start > 0 { stream.removeFirst(start) }
            guard stream.count >= 8 else { break }
            guard [0x31, 0x71].contains(stream[1]) else { stream.removeFirst(); continue }
            let length = Int(stream[2]) << 8 | Int(stream[3])
            guard (5...8192).contains(length) else { stream.removeFirst(); rejectedFrames += 1; continue }
            guard stream.count >= length + 8 else { break }
            let bytes = Array(stream.prefix(length + 8))
            let payload = Array(bytes.dropFirst(8))
            guard RingWire.crc(payload) == UInt16(bytes[4]) << 8 | UInt16(bytes[5]) else {
                stream.removeFirst(); rejectedFrames += 1; continue
            }
            stream.removeFirst(length + 8)
            let innerLength = Int(payload[3]) << 8 | Int(payload[4])
            guard payload.count == innerLength + 5 else { rejectedFrames += 1; continue }
            let key = Key(sequence: UInt16(bytes[6]) << 8 | UInt16(bytes[7]), command: payload[0], sub: payload[2])
            let body = Array(payload.dropFirst(5))
            if bytes[1] == 0x71 {
                if fragments[key] == nil {
                    guard fragments.count < 32 else { rejectedFrames += 1; continue }
                    fragments[key] = Fragment(data: [], time: now)
                }
                fragments[key]!.data += body
                if fragments[key]!.data.count > 16_384 { fragments.removeValue(forKey: key); rejectedFrames += 1 }
            } else {
                let combined = (fragments.removeValue(forKey: key)?.data ?? []) + body
                if key.command == 1, key.sub == 0x13 {
                    firmwareVersion = RingDeviceInformation.firmwareVersion(Data(combined))
                }
                if key.command == 0x83 {
                    bluetoothAddress = RingDeviceInformation.bluetoothAddress(subcommand: key.sub, body: Data(combined))
                    identityResponseDescription = String(format: "Identity response sub=0x%02X length=%d address=%@", key.sub, combined.count, bluetoothAddress == nil ? "unavailable" : "available")
                }
                if key.command == 4, key.sub == 0x41, combined.count == 2, combined[0] <= 100 {
                    batteryStatus = RingBatteryStatus(percent: Int(combined[0]), stateCode: combined[1])
                }
                if key.command == 0x0a {
                    receivedBlocks.append(RingHistoryBlock(command: key.command, subcommand: key.sub, payload: Data(combined), receivedAt: now))
                    readings += decode(sub: key.sub, body: combined, now: now, timeZone: timeZone)
                }
            }
        }
        return readings
    }

    private func decode(sub: UInt8, body: [UInt8], now: Date, timeZone: TimeZone) -> [RingReading] {
        if sub == 0xac, body.count >= 12 {
            func float(_ i: Int) -> Double {
                let bits = body[i..<i+4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                return Double(Float(bitPattern: bits))
            }
            return [(RingMetric.steps, Double(Int(body[2]) << 8 | Int(body[3]))), (.calories, float(4)), (.distance, float(8))]
                .filter { $0.0.accepts($0.1) }
                .map { RingReading(metric: $0.0, value: $0.1, date: now, isObservationTime: true) }
        }
        // Daily date/value quadruples. C8 matched the original app's PAI=90
        // (activity date 2026-11-07) in the user's 2026-11-08 comparison.
        // C7 remains unidentified and retains its neutral name.
        if sub == 0xc7 || sub == 0xc8 {
            guard !body.isEmpty, body.count % 4 == 0 else { return [] }
            var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
            var values: [RingReading] = []
            for offset in stride(from: 0, to: body.count, by: 4) {
                let year = Int(body[offset]) + 2000, month = Int(body[offset+1]), day = Int(body[offset+2])
                guard (2020...2040).contains(year), (1...12).contains(month), (1...31).contains(day),
                      let date = cal.date(from: DateComponents(year: year, month: month, day: day)), date <= now else { continue }
                let back = cal.dateComponents([.year, .month, .day], from: date)
                guard back.year == year, back.month == month, back.day == day else { continue }
                values.append(RingReading(metric: sub == 0xc7 ? .dailyIndexA : .pai, value: Double(body[offset+3]), date: date))
            }
            return values
        }
        let metric: RingMetric
        switch sub {
        case 0xa4: metric = .heartRate
        case 0xaf: metric = .oxygen
        case 0xbd: metric = .stress
        case 0xc5: metric = .mood
        case 0xc6: metric = .fatigue
        case 0xc9: metric = .hrv
        default: return []
        }
        let size = sub == 0xc5 ? 8 : 7
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        func date(at offset: Int) -> Date? {
            let r = Array(body[offset..<offset+6]).map(Int.init)
            guard (20...40).contains(r[0]), (1...12).contains(r[1]), (1...31).contains(r[2]),
                  r[3] < 24, r[4] < 60, r[5] < 60 else { return nil }
            let c = DateComponents(year: 2000+r[0], month: r[1], day: r[2], hour: r[3], minute: r[4], second: r[5])
            guard let date = calendar.date(from: c), date <= now.addingTimeInterval(300) else { return nil }
            let back = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            guard back.year == c.year, back.month == c.month, back.day == c.day, back.hour == c.hour,
                  back.minute == c.minute, back.second == c.second else { return nil }
            return date
        }
        guard body.count >= size else { return [] }
        // Search for a plausible alignment only within a leading prefix,
        // reject trailing partial records and select the alignment with most valid dates.
        let candidates = (0..<min(size, body.count)).filter { (body.count - $0) % size == 0 }
        guard let start = candidates.max(by: { a, b in
            stride(from: a, through: body.count-size, by: size).filter { date(at: $0) != nil }.count <
            stride(from: b, through: body.count-size, by: size).filter { date(at: $0) != nil }.count
        }) else { return [] }
        var result: [RingReading] = []
        for offset in stride(from: start, through: body.count-size, by: size) {
            guard let stamp = date(at: offset) else { continue }
            let value = Double(body[offset+6])
            if metric.accepts(value) { result.append(RingReading(metric: metric, value: value, date: stamp)) }
            if sub == 0xc5 {
                let respiration = Double(body[offset+7])
                if RingMetric.respiration.accepts(respiration) {
                    result.append(RingReading(metric: .respiration, value: respiration, date: stamp))
                }
            }
        }
        return result
    }
}
