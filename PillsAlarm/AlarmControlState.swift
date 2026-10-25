import Foundation
import WidgetKit

enum AlarmControlState {
    static let groupID = "group.com.kolisko.pillcare.controls"
    static let kind = "com.kolisko.pillcare.alarm-control"
    static let enabledKey = "alarmsEnabled"

    static func currentValue(defaults: UserDefaults? = UserDefaults(suiteName: groupID)) throws -> Bool {
        guard let value = defaults?.object(forKey: enabledKey) as? Bool else {
            AlarmControlDiagnostics.record(.controlReadFailed, fields: ["reason": "missingSharedState"], always: true)
            throw AlarmControlError.openAppFirst
        }
        AlarmControlDiagnostics.record(.controlRead, fields: ["enabled": "\(value)"], always: true)
        return value
    }

    // A read-only projection for the extension. The existing app preference remains authoritative.
    static func publish(_ enabled: Bool) {
        UserDefaults(suiteName: groupID)?.set(enabled, forKey: enabledKey)
        AlarmControlDiagnostics.record(.controlPublished, fields: ["enabled": "\(enabled)"], always: true)
        if #available(iOS 18.0, *) {
            ControlCenter.shared.reloadControls(ofKind: kind)
        }
    }
}

enum AlarmControlError: LocalizedError {
    case openAppFirst
    case plansUnavailable

    var errorDescription: String? {
        switch self {
        case .openAppFirst: "Nejprve otevřete aplikaci Pills Alarm."
        case .plansUnavailable: "Plány léků se nepodařilo načíst. Otevřete Pills Alarm a zkuste zapnutí znovu."
        }
    }
}
