import Foundation

public struct CareMember: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var displayName: String
    public var colorHex: String
    public var userRecordName: String?

    public init(id: UUID = UUID(), displayName: String, colorHex: String, userRecordName: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.colorHex = colorHex
        self.userRecordName = userRecordName
    }
}

public struct TimeOfDay: Codable, Hashable, Comparable, Sendable {
    public var hour: Int
    public var minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    public var label: String {
        String(format: "%02d:%02d", hour, minute)
    }

    public static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool {
        lhs.hour == rhs.hour ? lhs.minute < rhs.minute : lhs.hour < rhs.hour
    }
}

public struct DoseTime: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var label: String
    public var time: TimeOfDay

    public init(id: UUID = UUID(), label: String, time: TimeOfDay) {
        self.id = id
        self.label = label
        self.time = time
    }
}

public struct DoseEntry: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var timeId: UUID
    public var amount: Double

    public init(id: UUID = UUID(), timeId: UUID, amount: Double) {
        self.id = id
        self.timeId = timeId
        self.amount = DoseAmountFormatter.normalized(amount)
    }

    public init(id: UUID = UUID(), timeId: UUID, amount: String) {
        self.init(id: id, timeId: timeId, amount: DoseAmountFormatter.value(from: amount))
    }

    public enum CodingKeys: String, CodingKey, Sendable {
        case id
        case timeId
        case amount
    }

    public init(from decoder: Decoder) throws {
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

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(timeId, forKey: .timeId)
        try container.encode(DoseAmountFormatter.normalized(amount), forKey: .amount)
    }
}

public struct PlanPhase: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var durationDays: Int?
    public var doses: [DoseEntry]

    public init(id: UUID = UUID(), title: String, durationDays: Int?, doses: [DoseEntry]) {
        self.id = id
        self.title = title
        self.durationDays = durationDays
        self.doses = doses
    }
}

public struct Medication: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var note: String
    public var colorHex: String
    public var startDate: Date
    public var doseTimes: [DoseTime]
    public var phases: [PlanPhase]
    public var ownerUserRecordName: String?
    public var sharedGroupId: String?

    public var isSharedWithGroup: Bool {
        sharedGroupId != nil
    }

    public init(
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

    public enum CodingKeys: String, CodingKey, Sendable {
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

    public init(from decoder: Decoder) throws {
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

public enum DoseStatus: String, Codable, CaseIterable, Sendable {
    case confirmed
    case skipped

    public var label: String {
        switch self {
        case .confirmed: "Podáno"
        case .skipped: "Přeskočeno"
        }
    }
}

public struct DoseConfirmation: Identifiable, Codable, Hashable, Sendable {
    public var id: String { eventId }
    public var eventId: String
    public var medicationId: UUID
    public var timeId: UUID
    public var scheduledDate: Date
    public var amount: String
    public var status: DoseStatus
    public var memberId: UUID
    public var memberName: String
    public var timestamp: Date
    public var note: String

    public init(
        eventId: String,
        medicationId: UUID,
        timeId: UUID,
        scheduledDate: Date,
        amount: String,
        status: DoseStatus,
        memberId: UUID,
        memberName: String,
        timestamp: Date,
        note: String
    ) {
        self.eventId = eventId
        self.medicationId = medicationId
        self.timeId = timeId
        self.scheduledDate = scheduledDate
        self.amount = amount
        self.status = status
        self.memberId = memberId
        self.memberName = memberName
        self.timestamp = timestamp
        self.note = note
    }
}

public struct GeneratedDose: Identifiable, Hashable, Sendable {
    public var id: String
    public var baseEventId: String
    public var workspaceId: String
    public var isShared: Bool
    public var workspaceName: String
    public var medicationId: UUID
    public var medicationName: String
    public var medicationNote: String
    public var medicationColorHex: String
    public var timeId: UUID
    public var timeLabel: String
    public var scheduledDate: Date
    public var scheduledTime: TimeOfDay
    public var amount: String
    public var phaseTitle: String

    public init(
        id: String,
        baseEventId: String,
        workspaceId: String,
        isShared: Bool,
        workspaceName: String,
        medicationId: UUID,
        medicationName: String,
        medicationNote: String,
        medicationColorHex: String,
        timeId: UUID,
        timeLabel: String,
        scheduledDate: Date,
        scheduledTime: TimeOfDay,
        amount: String,
        phaseTitle: String
    ) {
        self.id = id
        self.baseEventId = baseEventId
        self.workspaceId = workspaceId
        self.isShared = isShared
        self.workspaceName = workspaceName
        self.medicationId = medicationId
        self.medicationName = medicationName
        self.medicationNote = medicationNote
        self.medicationColorHex = medicationColorHex
        self.timeId = timeId
        self.timeLabel = timeLabel
        self.scheduledDate = scheduledDate
        self.scheduledTime = scheduledTime
        self.amount = amount
        self.phaseTitle = phaseTitle
    }
}

public enum DoseAmountFormatter {
    public static func normalized(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return max(0, (value * 4).rounded() / 4)
    }

    public static func value(from text: String) -> Double {
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

    public static func displayText(for value: Double) -> String {
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
