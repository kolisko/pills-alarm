import Foundation

struct CareMember: Identifiable, Codable, Hashable {
    var id: UUID
    var displayName: String
    var colorHex: String

    init(id: UUID = UUID(), displayName: String, colorHex: String) {
        self.id = id
        self.displayName = displayName
        self.colorHex = colorHex
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
    var amount: String

    init(id: UUID = UUID(), timeId: UUID, amount: String) {
        self.id = id
        self.timeId = timeId
        self.amount = amount
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

    init(
        id: UUID = UUID(),
        name: String,
        note: String,
        colorHex: String,
        startDate: Date,
        doseTimes: [DoseTime],
        phases: [PlanPhase]
    ) {
        self.id = id
        self.name = name
        self.note = note
        self.colorHex = colorHex
        self.startDate = startDate
        self.doseTimes = doseTimes
        self.phases = phases
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
