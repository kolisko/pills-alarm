import Foundation

public struct ScheduledDoseAlarm: Equatable, Sendable {
    public var dose: GeneratedDose
    public var scheduledDate: Date
    public var repeatIndex: Int

    public init(dose: GeneratedDose, scheduledDate: Date, repeatIndex: Int) {
        self.dose = dose
        self.scheduledDate = scheduledDate
        self.repeatIndex = repeatIndex
    }
}

public struct ScheduledDoseAlarmGroup: Equatable, Sendable {
    public var scheduledDate: Date
    public var alarms: [ScheduledDoseAlarm]

    public var medicationCount: Int {
        Set(alarms.map(\.dose.medicationId)).count
    }

    public init(scheduledDate: Date, alarms: [ScheduledDoseAlarm]) {
        self.scheduledDate = scheduledDate
        self.alarms = alarms
    }
}

public struct AlarmSettings: Codable, Equatable, Sendable {
    public var repeatIntervalMinutes: Int
    public var repeatDurationMinutes: Int
    // Keep the persisted key; this limit now counts administration times, not individual doses.
    public var repeatingDoseLimit: Int

    public init(repeatIntervalMinutes: Int, repeatDurationMinutes: Int, repeatingDoseLimit: Int) {
        self.repeatIntervalMinutes = repeatIntervalMinutes
        self.repeatDurationMinutes = repeatDurationMinutes
        self.repeatingDoseLimit = repeatingDoseLimit
    }

    public static let defaultValue = AlarmSettings(
        repeatIntervalMinutes: 15,
        repeatDurationMinutes: 120,
        repeatingDoseLimit: 2
    )

    public var repeatOffsetsMinutes: [Int] {
        guard repeatIntervalMinutes > 0 else { return [0] }
        return Array(stride(from: 0, through: repeatDurationMinutes, by: repeatIntervalMinutes))
    }

    public var normalized: AlarmSettings {
        AlarmSettings(
            repeatIntervalMinutes: min(max(repeatIntervalMinutes, 5), 60),
            repeatDurationMinutes: min(max(repeatDurationMinutes, 15), 240),
            repeatingDoseLimit: min(max(repeatingDoseLimit, 1), 5)
        )
    }
}

public enum AlarmSchedulingRules {
    public static let scheduleHorizonDays = 7
    public static let scheduleLookbackDays = 1

    public static func upcomingAlarms(
        now: Date,
        settings: AlarmSettings,
        dosesForDate: (Date) -> [GeneratedDose],
        confirmationForDose: (GeneratedDose) -> DoseConfirmation?,
        calendar: Calendar = .current
    ) -> [ScheduledDoseAlarm] {
        let settings = settings.normalized
        let repeatOffsets = settings.repeatOffsetsMinutes
        var schedulableDoses: [GeneratedDose] = []

        for dayOffset in -scheduleLookbackDays..<scheduleHorizonDays {
            guard let date = calendar.date(byAdding: .day, value: dayOffset, to: now) else { continue }
            let doses = dosesForDate(date)
            for dose in doses where confirmationForDose(dose) == nil {
                let hasFutureAlarm = repeatOffsets.contains { offset in
                    guard let scheduledDate = calendar.date(byAdding: .minute, value: offset, to: dose.scheduledDate) else {
                        return false
                    }

                    return scheduledDate > now
                }

                if hasFutureAlarm {
                    schedulableDoses.append(dose)
                }
            }
        }

        let doseMinutes = Set(schedulableDoses.map { minuteStart(for: $0.scheduledDate, calendar: calendar) })
        let repeatingMinutes = Set(doseMinutes.sorted().prefix(settings.repeatingDoseLimit))

        return schedulableDoses.flatMap { dose in
            let doseMinute = minuteStart(for: dose.scheduledDate, calendar: calendar)
            let offsets = repeatingMinutes.contains(doseMinute) ? repeatOffsets : [0]
            return offsets.enumerated().compactMap { index, offset -> ScheduledDoseAlarm? in
                guard let scheduledDate = calendar.date(byAdding: .minute, value: offset, to: dose.scheduledDate),
                      scheduledDate > now else {
                    return nil
                }

                return ScheduledDoseAlarm(dose: dose, scheduledDate: scheduledDate, repeatIndex: index)
            }
        }
        .sorted { lhs, rhs in
            if lhs.scheduledDate == rhs.scheduledDate {
                return lhs.dose.id < rhs.dose.id
            }
            return lhs.scheduledDate < rhs.scheduledDate
        }
    }

    public static func groupedByMinute(
        _ alarms: [ScheduledDoseAlarm],
        calendar: Calendar = .current
    ) -> [ScheduledDoseAlarmGroup] {
        let grouped = Dictionary(grouping: alarms) { alarm in
            minuteStart(for: alarm.scheduledDate, calendar: calendar)
        }

        return grouped.values.compactMap { alarms in
            let sortedAlarms = alarms.sorted { lhs, rhs in
                if lhs.scheduledDate != rhs.scheduledDate {
                    return lhs.scheduledDate < rhs.scheduledDate
                }
                if lhs.dose.id != rhs.dose.id {
                    return lhs.dose.id < rhs.dose.id
                }
                return lhs.repeatIndex < rhs.repeatIndex
            }
            guard let firstAlarm = sortedAlarms.first else { return nil }
            return ScheduledDoseAlarmGroup(
                scheduledDate: firstAlarm.scheduledDate,
                alarms: sortedAlarms
            )
        }
        .sorted { lhs, rhs in
            lhs.scheduledDate < rhs.scheduledDate
        }
    }

    private static func minuteStart(for date: Date, calendar: Calendar) -> Date {
        calendar.dateInterval(of: .minute, for: date)?.start ?? date
    }
}
