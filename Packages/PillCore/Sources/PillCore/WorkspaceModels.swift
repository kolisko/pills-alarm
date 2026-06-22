import Foundation

public struct WorkspaceSource: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var isShared: Bool

    public init(id: String, name: String, isShared: Bool) {
        self.id = id
        self.name = name
        self.isShared = isShared
    }
}

public struct MedicationListItem: Identifiable, Hashable, Sendable {
    public var medication: Medication
    public var source: WorkspaceSource

    public var id: String {
        "\(source.id)|\(medication.id.uuidString)"
    }

    public init(medication: Medication, source: WorkspaceSource) {
        self.medication = medication
        self.source = source
    }
}

public struct ConfirmationListItem: Identifiable, Hashable, Sendable {
    public var confirmation: DoseConfirmation
    public var source: WorkspaceSource

    public var id: String {
        "\(source.id)|\(confirmation.eventId)"
    }

    public init(confirmation: DoseConfirmation, source: WorkspaceSource) {
        self.confirmation = confirmation
        self.source = source
    }
}

public struct SharedWorkspaceProfile: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var currentMemberName: String
    public var otherMembers: [CareMember]

    public init(id: String, name: String, currentMemberName: String, otherMembers: [CareMember]) {
        self.id = id
        self.name = name
        self.currentMemberName = currentMemberName
        self.otherMembers = otherMembers
    }
}
