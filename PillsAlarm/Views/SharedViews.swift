import SwiftUI
import UIKit
import PillCore

struct StatusBadge: View {
    var text: String
    var systemImage: String
    var tint: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(tint)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

struct EmptyStateView: View {
    var title: String
    var systemImage: String

    var body: some View {
        ContentUnavailableView(title, systemImage: systemImage)
    }
}

struct LoadingStateView: View {
    var body: some View {
        RefreshSpinner()
            .frame(maxWidth: .infinity, minHeight: 420, alignment: .center)
    }
}

private struct RefreshSpinner: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        let indicator = UIActivityIndicatorView(style: .large)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.hidesWhenStopped = false
        indicator.startAnimating()
        container.addSubview(indicator)

        NSLayoutConstraint.activate([
            indicator.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            indicator.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            indicator.widthAnchor.constraint(equalToConstant: 37),
            indicator.heightAnchor.constraint(equalToConstant: 37)
        ])

        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        uiView.subviews
            .compactMap { $0 as? UIActivityIndicatorView }
            .forEach { $0.startAnimating() }
    }
}

struct CloudBackedEmptyStateView: View {
    var loadState: MedicationStore.LoadState
    var emptyTitle: String
    var systemImage: String

    var body: some View {
        switch loadState {
        case .idle, .loading:
            LoadingStateView()

        case .ready:
            EmptyStateView(title: emptyTitle, systemImage: systemImage)

        case .requiresICloudAccount, .missingGroup, .failed:
            EmptyView()
        }
    }
}

struct AppScreen<Content: View, Trailing: View>: View {
    var title: String
    var subtitle: String?
    var titleColor: Color
    var titleAction: (() -> Void)?
    private let content: Content
    private let trailing: Trailing

    init(
        title: String,
        subtitle: String? = nil,
        titleColor: Color = .primary,
        titleAction: (() -> Void)? = nil,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.titleColor = titleColor
        self.titleAction = titleAction
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            titleBlock
            .layoutPriority(0)
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Color(.systemBackground))
        .zIndex(1)
    }

    @ViewBuilder
    private var titleBlock: some View {
        if let titleAction {
            Button(action: titleAction) {
                titleContent
            }
            .buttonStyle(HeaderTitleButtonStyle())
        } else {
            titleContent
        }
    }

    private var titleContent: some View {
        ZStack(alignment: .leading) {
            Text(title)
                .font(.largeTitle.bold())
                .foregroundStyle(titleColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            if let subtitle {
                Text(subtitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .offset(x: 2, y: 21)
            }
        }
    }
}

private struct HeaderTitleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension AppScreen where Trailing == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        titleColor: Color = .primary,
        @ViewBuilder content: () -> Content
    ) {
        self.init(title: title, subtitle: subtitle, titleColor: titleColor, titleAction: nil, trailing: { EmptyView() }, content: content)
    }
}

extension Color {
    init(hex: String) {
        var clean = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        clean.removeAll { $0 == "#" }

        var value: UInt64 = 0
        Scanner(string: clean).scanHexInt64(&value)

        let red = Double((value >> 16) & 0xFF) / 255.0
        let green = Double((value >> 8) & 0xFF) / 255.0
        let blue = Double(value & 0xFF) / 255.0
        self.init(red: red, green: green, blue: blue)
    }
}

extension Date {
    var shortDayLabel: String {
        formatted(.dateTime.weekday(.wide).day().month())
    }

    var shortTimeLabel: String {
        formatted(.dateTime.hour().minute())
    }

    func relativeDayLabel(referenceDate: Date = Date(), calendar: Calendar = .current) -> String {
        let referenceStart = calendar.startOfDay(for: referenceDate)
        let targetStart = calendar.startOfDay(for: self)
        let dayOffset = calendar.dateComponents([.day], from: referenceStart, to: targetStart).day ?? 0

        switch dayOffset {
        case -2:
            return "Předevčírem"
        case -1:
            return "Včera"
        case 0:
            return "Dnes"
        case 1:
            return "Zítra"
        case 2:
            return "Pozítří"
        default:
            return formatted(.dateTime.locale(Locale(identifier: "cs_CZ")).weekday(.wide).day().month())
        }
    }

    func relativeDayTitle(referenceDate: Date = Date(), calendar: Calendar = .current) -> String {
        let referenceStart = calendar.startOfDay(for: referenceDate)
        let targetStart = calendar.startOfDay(for: self)
        let dayOffset = calendar.dateComponents([.day], from: referenceStart, to: targetStart).day ?? 0

        switch dayOffset {
        case -2:
            return "Předevčírem"
        case -1:
            return "Včera"
        case 0:
            return "Dnes"
        case 1:
            return "Zítra"
        case 2:
            return "Pozítří"
        default:
            return formatted(.dateTime.locale(Locale(identifier: "cs_CZ")).weekday(.wide)).capitalized
        }
    }

    func relativeDayAndDateLabel(referenceDate: Date = Date(), calendar: Calendar = .current) -> String {
        let date = formatted(.dateTime.locale(Locale(identifier: "cs_CZ")).day().month().year())
        return "\(relativeDayTitle(referenceDate: referenceDate, calendar: calendar)), \(date)"
    }

    func relativeWeekdaySubtitle(referenceDate: Date = Date(), calendar: Calendar = .current) -> String? {
        let referenceStart = calendar.startOfDay(for: referenceDate)
        let targetStart = calendar.startOfDay(for: self)
        let dayOffset = calendar.dateComponents([.day], from: referenceStart, to: targetStart).day ?? 0

        guard (-2...2).contains(dayOffset) else { return nil }
        return czechWeekdayName()
    }

    private func czechWeekdayName() -> String {
        let locale = Locale(identifier: "cs_CZ")
        let name = formatted(.dateTime.locale(locale).weekday(.wide))
        guard let first = name.first else { return name }
        return String(first).uppercased(with: locale) + name.dropFirst()
    }

    func isSameDay(as other: Date, calendar: Calendar = .current) -> Bool {
        calendar.isDate(self, inSameDayAs: other)
    }
}
