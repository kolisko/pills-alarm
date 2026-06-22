import Foundation

public enum MedicationFactory {
    public static func newMedication(now: Date = Date(), calendar: Calendar = .current) -> Medication {
        let morning = DoseTime(label: "Ráno", time: TimeOfDay(hour: 7, minute: 0))
        let noon = DoseTime(label: "Poledne", time: TimeOfDay(hour: 12, minute: 0))
        let evening = DoseTime(label: "Večer", time: TimeOfDay(hour: 19, minute: 0))
        return Medication(
            name: "Nový lék",
            note: "",
            colorHex: "#2F80ED",
            startDate: calendar.startOfDay(for: now),
            doseTimes: [morning, noon, evening],
            phases: [
                PlanPhase(
                    title: "Základní dávkování",
                    durationDays: nil,
                    doses: [
                        DoseEntry(timeId: morning.id, amount: 0),
                        DoseEntry(timeId: noon.id, amount: 0),
                        DoseEntry(timeId: evening.id, amount: 0)
                    ]
                )
            ]
        )
    }
}
