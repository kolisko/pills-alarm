import SwiftUI
import UserNotifications

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        AlarmAuditView()
                    } label: {
                        Label("Alarmy", systemImage: "bell.badge")
                    }

                    NavigationLink {
                        AlarmSettingsView()
                    } label: {
                        Label("Nastavení alarmů", systemImage: "slider.horizontal.3")
                    }

                    NavigationLink {
                        SyncSettingsView()
                    } label: {
                        Label("Synchronizace", systemImage: "arrow.triangle.2.circlepath")
                    }

                    NavigationLink {
                        VersionInfoView()
                    } label: {
                        Label("Verze", systemImage: "info.circle")
                    }
                }
            }
            .navigationTitle("Nastavení")
        }
    }
}

struct AlarmAuditView: View {
    @EnvironmentObject private var store: MedicationStore
    @ObservedObject private var scheduler = NotificationScheduler.shared
    @State private var settings: UNNotificationSettings?
    @State private var pendingAlarms: [ScheduledAlarmInfo] = []

    var body: some View {
        List {
            Section("Oprávnění") {
                AuditRow(
                    title: "Notifikace",
                    value: authorizationLabel,
                    systemImage: authorizationIsUsable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                    tint: authorizationIsUsable ? .green : .orange
                )
                AuditRow(
                    title: "Zvuk",
                    value: settingLabel(settings?.soundSetting),
                    systemImage: settings?.soundSetting == .enabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                    tint: settings?.soundSetting == .enabled ? .green : .orange
                )
                AuditRow(
                    title: "Critical Alerts",
                    value: settingLabel(settings?.criticalAlertSetting),
                    systemImage: settings?.criticalAlertSetting == .enabled ? "exclamationmark.octagon.fill" : "exclamationmark.octagon",
                    tint: settings?.criticalAlertSetting == .enabled ? .green : .secondary
                )
            }

            Section("Plánování") {
                AuditRow(
                    title: "Zvuk alarmu",
                    value: "\(NotificationScheduler.doseAlarmDurationSeconds) s",
                    systemImage: "speaker.wave.3.fill",
                    tint: .teal
                )

                AuditRow(
                    title: "Opakování",
                    value: "po \(scheduler.alarmSettings.repeatIntervalMinutes) min / \(scheduler.alarmSettings.repeatDurationMinutes) min",
                    systemImage: "repeat",
                    tint: .teal
                )

                AuditRow(
                    title: "Série pro dávky",
                    value: "\(scheduler.alarmSettings.repeatingDoseLimit) nejbližší",
                    systemImage: "list.number",
                    tint: .teal
                )

                AuditRow(
                    title: "Naplánováno",
                    value: "\(scheduler.lastScheduledCount)",
                    systemImage: "calendar.badge.clock",
                    tint: scheduler.lastScheduledCount > 0 ? .green : .secondary
                )

                AuditRow(
                    title: "Poslední kontrola",
                    value: scheduler.lastSchedulingDate?.formatted(date: .abbreviated, time: .shortened) ?? "Zatím neproběhla",
                    systemImage: "clock",
                    tint: .secondary
                )

                if let error = scheduler.lastSchedulingError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }

                Button {
                    scheduler.rescheduleUpcomingDoses(store: store)
                    Task {
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        await refreshAudit()
                    }
                } label: {
                    Label("Přeplánovat alarmy", systemImage: "arrow.clockwise")
                }
            }

            Section("Čekající alarmy") {
                if pendingAlarms.isEmpty {
                    EmptyStateView(title: "Žádné alarmy nejsou naplánované", systemImage: "bell.slash")
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(pendingAlarms) { alarm in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(alarm.scheduledDate.relativeDayLabel())
                                    .font(.headline)
                                Spacer()
                                Text(alarm.scheduledDate.shortTimeLabel)
                                    .font(.headline.monospacedDigit())
                            }
                            Text(alarm.title)
                                .font(.subheadline.weight(.semibold))
                            if !alarm.body.isEmpty {
                                Text(alarm.body)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle("Alarmy")
        .refreshable {
            await refreshAudit()
        }
        .task {
            await refreshAudit()
        }
    }

    private var authorizationLabel: String {
        guard let status = settings?.authorizationStatus else {
            return "Načítám"
        }

        switch status {
        case .notDetermined:
            return "Nevyžádáno"
        case .denied:
            return "Zakázáno"
        case .authorized:
            return "Povoleno"
        case .provisional:
            return "Dočasně povoleno"
        case .ephemeral:
            return "Dočasné"
        @unknown default:
            return "Neznámé"
        }
    }

    private var authorizationIsUsable: Bool {
        switch settings?.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        default:
            return false
        }
    }

    private func settingLabel(_ setting: UNNotificationSetting?) -> String {
        guard let setting else { return "Načítám" }

        switch setting {
        case .enabled:
            return "Povoleno"
        case .disabled:
            return "Zakázáno"
        case .notSupported:
            return "Nepodporováno"
        @unknown default:
            return "Neznámé"
        }
    }

    private func refreshAudit() async {
        settings = await scheduler.notificationSettings()
        pendingAlarms = await scheduler.pendingDoseAlarms()
    }
}

private struct SyncSettingsView: View {
    @AppStorage(SyncSettings.autoRefreshIntervalMinutesKey) private var autoRefreshIntervalMinutes = SyncSettings.defaultAutoRefreshIntervalMinutes

    var body: some View {
        List {
            Section("Otevřená aplikace") {
                Stepper(
                    "Batch autorefresh: \(autoRefreshIntervalMinutes) min",
                    value: autoRefreshIntervalBinding,
                    in: SyncSettings.minimumAutoRefreshIntervalMinutes...SyncSettings.maximumAutoRefreshIntervalMinutes
                )
            }

            Section {
                Button {
                    autoRefreshIntervalMinutes = SyncSettings.defaultAutoRefreshIntervalMinutes
                } label: {
                    Label("Obnovit výchozí nastavení", systemImage: "arrow.counterclockwise")
                }
            }
        }
        .navigationTitle("Synchronizace")
    }

    private var autoRefreshIntervalBinding: Binding<Int> {
        Binding {
            SyncSettings.normalizedAutoRefreshIntervalMinutes(autoRefreshIntervalMinutes)
        } set: { value in
            autoRefreshIntervalMinutes = SyncSettings.normalizedAutoRefreshIntervalMinutes(value)
        }
    }
}

private struct AlarmSettingsView: View {
    @EnvironmentObject private var store: MedicationStore
    @ObservedObject private var scheduler = NotificationScheduler.shared

    var body: some View {
        List {
            Section {
                AuditRow(
                    title: "Délka zvuku",
                    value: "\(NotificationScheduler.doseAlarmDurationSeconds) s",
                    systemImage: "speaker.wave.3.fill",
                    tint: .teal
                )
            } header: {
                Text("Zvuk")
            } footer: {
                Text("Délka zvuku je daná souborem v aplikaci a nejde ji měnit dynamicky.")
            }

            Section {
                Stepper(
                    "Interval: \(scheduler.alarmSettings.repeatIntervalMinutes) min",
                    value: alarmSettingBinding(\.repeatIntervalMinutes),
                    in: 5...60,
                    step: 5
                )

                Stepper(
                    "Délka série: \(scheduler.alarmSettings.repeatDurationMinutes) min",
                    value: alarmSettingBinding(\.repeatDurationMinutes),
                    in: 15...240,
                    step: 15
                )

                Stepper(
                    "Série pro dávky: \(scheduler.alarmSettings.repeatingDoseLimit)",
                    value: alarmSettingBinding(\.repeatingDoseLimit),
                    in: 1...5
                )
            } header: {
                Text("Opakovací série")
            } footer: {
                Text("Opakování se vytváří jen pro nejbližší nepotvrzené dávky. Vzdálenější dávky mají první alarm a série se jim doplní, až na ně přijde řada.")
            }

            Section {
                Button {
                    scheduler.alarmSettings = .defaultValue
                    scheduler.rescheduleUpcomingDoses(store: store)
                } label: {
                    Label("Obnovit výchozí nastavení", systemImage: "arrow.counterclockwise")
                }
            }
        }
        .navigationTitle("Nastavení alarmů")
    }

    private func alarmSettingBinding(_ keyPath: WritableKeyPath<AlarmSettings, Int>) -> Binding<Int> {
        Binding {
            scheduler.alarmSettings[keyPath: keyPath]
        } set: { value in
            var next = scheduler.alarmSettings
            next[keyPath: keyPath] = value
            scheduler.alarmSettings = next.normalized
            scheduler.rescheduleUpcomingDoses(store: store)
        }
    }
}

private struct AuditRow: View {
    var title: String
    var value: String
    var systemImage: String
    var tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: 24)
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct VersionInfoView: View {
    private let info = AppVersionInfo.current

    var body: some View {
        List {
            Section("Aplikace") {
                AuditRow(title: "Verze", value: info.version, systemImage: "app.badge", tint: .teal)
                AuditRow(title: "Build", value: info.build, systemImage: "number", tint: .teal)
                AuditRow(title: "Typ buildu", value: info.buildType, systemImage: "hammer.fill", tint: .secondary)
                AuditRow(title: "Platforma", value: info.platform, systemImage: "iphone", tint: .secondary)
            }

            Section("iCloud") {
                AuditRow(title: "CloudKit", value: info.cloudKitEnvironment, systemImage: "icloud.fill", tint: info.cloudKitTint)
                AuditRow(title: "Push", value: info.pushEnvironment, systemImage: "bell.badge.fill", tint: .secondary)
                AuditRow(title: "Container", value: info.iCloudContainers, systemImage: "externaldrive.connected.to.line.below.fill", tint: .secondary)
            }

            Section("Identifikace") {
                AuditRow(title: "Bundle ID", value: info.bundleIdentifier, systemImage: "tag.fill", tint: .secondary)
                AuditRow(title: "Služby", value: info.iCloudServices, systemImage: "checklist", tint: .secondary)
            }
        }
        .navigationTitle("Verze")
    }
}

private struct AppVersionInfo {
    var version: String
    var build: String
    var buildType: String
    var platform: String
    var bundleIdentifier: String
    var cloudKitEnvironment: String
    var pushEnvironment: String
    var iCloudContainers: String
    var iCloudServices: String

    var cloudKitTint: Color {
        cloudKitEnvironment.localizedCaseInsensitiveContains("production") ? .green : .orange
    }

    static var current: AppVersionInfo {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Neznámá"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Neznámý"
        let bundleIdentifier = bundle.bundleIdentifier ?? "Neznámé"
        let cloudKitEnvironment = bundle.object(forInfoDictionaryKey: "PillCareCloudKitEnvironment") as? String
            ?? "Neurčeno"
        let pushEnvironment = bundle.object(forInfoDictionaryKey: "PillCareAPSEnvironment") as? String
            ?? "Neurčeno"
        let iCloudContainers = bundle.object(forInfoDictionaryKey: "PillCareICloudContainer") as? String
            ?? "Neurčeno"
        let iCloudServices = "CloudKit"

        return AppVersionInfo(
            version: version,
            build: build,
            buildType: buildType,
            platform: platform,
            bundleIdentifier: bundleIdentifier,
            cloudKitEnvironment: cloudKitEnvironment,
            pushEnvironment: pushEnvironment,
            iCloudContainers: iCloudContainers,
            iCloudServices: iCloudServices
        )
    }

    private static var buildType: String {
#if DEBUG
        "Debug"
#else
        "Release"
#endif
    }

    private static var platform: String {
#if targetEnvironment(simulator)
        "iOS simulátor"
#else
        "iOS zařízení"
#endif
    }

}
