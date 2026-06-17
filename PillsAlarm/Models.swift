import Foundation

struct CareMember: Identifiable, Codable, Hashable {
    var id: UUID
    var displayName: String
    var colorHex: String
    var userRecordName: String?

    init(id: UUID = UUID(), displayName: String, colorHex: String, userRecordName: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.colorHex = colorHex
        self.userRecordName = userRecordName
    }
}

struct TimeOfDay: Codable, Hashable, Comparable {
    var hour: Int
    var minute: Int

    var label: String {
        String(format: "%02d:%02d", hour, minute)
    }

    static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool {
        lhs.hour == rhs.hour ? lhs.minute < rhs.minute : lhs.hour < rhs.hour
    }
}

struct DoseTime: Identifiable, Codable, Hashable {
    var id: UUID
    var label: String
    var time: TimeOfDay

    init(id: UUID = UUID(), label: String, time: TimeOfDay) {
        self.id = id
        self.label = label
        self.time = time
    }
}

struct DoseEntry: Identifiable, Codable, Hashable {
    var id: UUID
    var timeId: UUID
    var amount: Double

    init(id: UUID = UUID(), timeId: UUID, amount: Double) {
        self.id = id
        self.timeId = timeId
        self.amount = DoseAmountFormatter.normalized(amount)
    }

    init(id: UUID = UUID(), timeId: UUID, amount: String) {
        self.init(id: id, timeId: timeId, amount: DoseAmountFormatter.value(from: amount))
    }

    enum CodingKeys: String, CodingKey {
        case id
        case timeId
        case amount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        timeId = try container.decode(UUID.self, forKey: .timeId)

        if let value = try? container.decode(Double.self, forKey: .amount) {
            amount = DoseAmountFormatter.normalized(value)
        } else {
            let value = try container.decode(String.self, forKey: .amount)
            amount = DoseAmountFormatter.value(from: value)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(timeId, forKey: .timeId)
        try container.encode(DoseAmountFormatter.normalized(amount), forKey: .amount)
    }
}

struct PlanPhase: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var durationDays: Int?
    var doses: [DoseEntry]

    init(id: UUID = UUID(), title: String, durationDays: Int?, doses: [DoseEntry]) {
        self.id = id
        self.title = title
        self.durationDays = durationDays
        self.doses = doses
    }
}

struct Medication: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var note: String
    var colorHex: String
    var startDate: Date
    var doseTimes: [DoseTime]
    var phases: [PlanPhase]
    var ownerUserRecordName: String?
    var sharedGroupId: String?

    var isSharedWithGroup: Bool {
        sharedGroupId != nil
    }

    init(
        id: UUID = UUID(),
        name: String,
        note: String,
        colorHex: String,
        startDate: Date,
        doseTimes: [DoseTime],
        phases: [PlanPhase],
        ownerUserRecordName: String? = nil,
        sharedGroupId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.note = note
        self.colorHex = colorHex
        self.startDate = startDate
        self.doseTimes = doseTimes
        self.phases = phases
        self.ownerUserRecordName = ownerUserRecordName
        self.sharedGroupId = sharedGroupId
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case note
        case colorHex
        case startDate
        case doseTimes
        case phases
        case ownerUserRecordName
        case sharedGroupId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        note = try container.decode(String.self, forKey: .note)
        colorHex = try container.decode(String.self, forKey: .colorHex)
        startDate = try container.decode(Date.self, forKey: .startDate)
        doseTimes = try container.decode([DoseTime].self, forKey: .doseTimes)
        phases = try container.decode([PlanPhase].self, forKey: .phases)
        ownerUserRecordName = try container.decodeIfPresent(String.self, forKey: .ownerUserRecordName)
        sharedGroupId = try container.decodeIfPresent(String.self, forKey: .sharedGroupId)
    }
}

enum DoseStatus: String, Codable, CaseIterable {
    case confirmed
    case skipped

    var label: String {
        switch self {
        case .confirmed: "Podáno"
        case .skipped: "Přeskočeno"
        }
    }
}

struct DoseConfirmation: Identifiable, Codable, Hashable {
    var id: String { eventId }
    var eventId: String
    var medicationId: UUID
    var timeId: UUID
    var scheduledDate: Date
    var amount: String
    var status: DoseStatus
    var memberId: UUID
    var memberName: String
    var timestamp: Date
    var note: String
}

struct GeneratedDose: Identifiable, Hashable {
    var id: String
    var baseEventId: String
    var workspaceId: String
    var isShared: Bool
    var workspaceName: String
    var medicationId: UUID
    var medicationName: String
    var medicationNote: String
    var medicationColorHex: String
    var timeId: UUID
    var timeLabel: String
    var scheduledDate: Date
    var scheduledTime: TimeOfDay
    var amount: String
    var phaseTitle: String
}

enum DoseAmountFormatter {
    static func normalized(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return max(0, (value * 4).rounded() / 4)
    }

    static func value(from text: String) -> Double {
        let clean = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")

        guard !clean.isEmpty else { return 0 }

        var total = 0.0
        var parsedAnyToken = false

        for token in clean.split(separator: " ") {
            if let fraction = fractionValue(from: String(token)) {
                total += fraction
                parsedAnyToken = true
            } else if let value = Double(token) {
                total += value
                parsedAnyToken = true
            }
        }

        if parsedAnyToken {
            return normalized(total)
        }

        return normalized(fractionValue(from: clean) ?? 0)
    }

    static func displayText(for value: Double) -> String {
        let normalizedValue = normalized(value)
        let quarters = Int((normalizedValue * 4).rounded())
        let whole = quarters / 4
        let fraction = quarters % 4
        let fractionText: String

        switch fraction {
        case 1:
            fractionText = "¼"
        case 2:
            fractionText = "½"
        case 3:
            fractionText = "¾"
        default:
            fractionText = ""
        }

        if whole == 0 {
            return fractionText.isEmpty ? "0" : fractionText
        }

        return fractionText.isEmpty ? "\(whole)" : "\(whole) \(fractionText)"
    }

    private static func fractionValue(from text: String) -> Double? {
        switch text {
        case "¼", "1/4":
            return 0.25
        case "½", "1/2":
            return 0.5
        case "¾", "3/4":
            return 0.75
        default:
            let parts = text.split(separator: "/")
            guard parts.count == 2,
                  let numerator = Double(parts[0]),
                  let denominator = Double(parts[1]),
                  denominator != 0 else {
                return nil
            }
            return numerator / denominator
        }
    }
}
