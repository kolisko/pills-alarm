import AppIntents
import SwiftUI
import WidgetKit

@main
struct PillsAlarmControls: WidgetBundle {
    var body: some Widget {
        PillsAlarmsControl()
    }
}

struct PillsAlarmsControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: AlarmControlState.kind, provider: Provider()) { state in
            ControlWidgetToggle("Alarmy Pills", isOn: state.displayedIsMuted, action: SetPillsAlarmsMutedIntent()) { isMuted in
                Label {
                    Text(state.displayedStatus(isMuted: isMuted))
                } icon: {
                    symbol(for: state, isMuted: isMuted)
                }
                .controlWidgetStatus(state.displayedStatus(isMuted: isMuted))
            }
            .disabled(state.isChanging)
            .tint(.red)
        }
        .displayName("Alarmy Pills")
        .description("Zapne nebo vypne všechny alarmy Pills na tomto iPhonu.")
    }

    private func symbol(for state: AlarmControlSnapshot, isMuted: Bool) -> Image {
        if state.pendingTarget(isMuted: isMuted) != nil { return Image(.pillsAlarmsPending) }
        if state.needsRecovery { return Image(systemName: "exclamationmark.arrow.triangle.2.circlepath") }
        return Image(isMuted ? .pillsAlarmsOff : .pillsAlarmsOn)
    }

    struct Provider: ControlValueProvider {
        var previewValue: AlarmControlSnapshot { AlarmControlSnapshot(enabled: true) }

        func currentValue() async throws -> AlarmControlSnapshot {
            try await AlarmControlState.store.snapshot()
        }
    }
}
