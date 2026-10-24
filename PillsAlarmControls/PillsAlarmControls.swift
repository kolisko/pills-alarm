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
        StaticControlConfiguration(kind: AlarmControlState.kind, provider: Provider()) { enabled in
            ControlWidgetToggle("Alarmy Pills", isOn: !enabled, action: SetPillsAlarmsMutedIntent()) { isMuted in
                Label(isMuted ? "Vypnuté" : "Zapnuté", image: isMuted ? .pillsAlarmsOff : .pillsAlarmsOn)
            }
            .tint(.red)
        }
        .displayName("Alarmy Pills")
        .description("Zapne nebo vypne všechny alarmy Pills na tomto iPhonu.")
    }

    struct Provider: ControlValueProvider {
        var previewValue: Bool { true }

        func currentValue() async throws -> Bool {
            try AlarmControlState.currentValue()
        }
    }
}
