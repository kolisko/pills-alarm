import Foundation

enum StoreError: LocalizedError {
    case missingCloudWorkspace
    case missingGroup
    case missingSharedMemberName
    case notPlanOwner

    var errorDescription: String? {
        switch self {
        case .missingCloudWorkspace:
            return "iCloud úložiště ještě není připravené. Chvíli počkej a zkus uložit znovu."
        case .missingGroup:
            return "Nejdřív vytvoř skupinu, potom můžeš plán sdílet."
        case .missingSharedMemberName:
            return "Nejdřív ve Skupině vyplň svoje jméno pro sdílenou skupinu."
        case .notPlanOwner:
            return "Sdílení a úpravy tohohle plánu může měnit jen vlastník plánu."
        }
    }
}
