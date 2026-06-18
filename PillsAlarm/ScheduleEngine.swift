import Foundation

enum ScheduleEngine {
    static func doses(on date: Date, medications: [Medication], calendar: Calendar = .current) -> [GeneratedDose] {
        medications.flatMap { medication in
            doses(on: date, medication: medication, calendar: calendar)
        }
        .sorted {
            if $0.scheduledDate == $1.scheduledDate {
                return $0.medicationName < $1.medicationName
            }
            return $0.scheduledDate < $1.scheduledDate
        }
    }

    static func doses(
        on date: Date,
        medication: Medication,
        workspaceId: String = "",
        isShared: Bool = false,
        workspaceName: String = "",
        calendar: Calendar = .current
    ) -> [GeneratedDose] {
        guard let phase = phase(for: date, medication: medication, calendar: calendar) else {
            return []
        }

        return medication.doseTimes.compactMap { doseTime in
            guard let entry = phase.doses.first(where: { $0.timeId == doseTime.id }) else {
                return nil
            }

            let amount = DoseAmountFormatter.normalized(entry.amount)
            guard amount > 0 else {
                return nil
            }

            let scheduledDate = calendar.date(
                bySettingHour: doseTime.time.hour,
                minute: doseTime.time.minute,
                second: 0,
                of: date
            ) ?? date
            let baseEventId = eventId(medicationId: medication.id, timeId: doseTime.id, scheduledDate: scheduledDate, calendar: calendar)

            return GeneratedDose(
                id: baseEventId,
                baseEventId: baseEventId,
                workspaceId: workspaceId,
                isShared: isShared,
                workspaceName: workspaceName,
                medicationId: medication.id,
                medicationName: medication.name,
                medicationNote: medication.note,
                medicationColorHex: medication.colorHex,
                timeId: doseTime.id,
                timeLabel: doseTime.label,
                scheduledDate: scheduledDate,
                scheduledTime: doseTime.time,
                amount: DoseAmountFormatter.displayText(for: amount),
                phaseTitle: phase.title
            )
        }
    }

    static func eventId(medicationId: UUID, timeId: UUID, scheduledDate: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: scheduledDate)
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        return "\(medicationId.uuidString)-\(timeId.uuidString)-\(String(format: "%04d%02d%02d", year, month, day))"
    }

    private static func phase(for date: Date, medication: Medication, calendar: Calendar) -> PlanPhase? {
        let start = calendar.startOfDay(for: medication.startDate)
        let target = calendar.startOfDay(for: date)
        guard let dayOffset = calendar.dateComponents([.day], from: start, to: target).day, dayOffset >= 0 else {
            return nil
        }

        var remaining = dayOffset
        for phase in medication.phases {
            guard let duration = phase.durationDays else {
                return phase
            }

            if remaining < duration {
                return phase
            }

            remaining -= duration
        }

        return medication.phases.last(where: { $0.durationDays == nil })
    }
}
