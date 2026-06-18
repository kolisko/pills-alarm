import SwiftUI

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

struct AppScreen<Content: View, Trailing: View>: View {
    var title: String
    var titleColor: Color
    private let content: Content
    private let trailing: Trailing

    init(
        title: String,
        titleColor: Color = .primary,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.titleColor = titleColor
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
            Text(title)
                .font(.largeTitle.bold())
                .foregroundStyle(titleColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
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
    }
}

extension AppScreen where Trailing == EmptyView {
    init(
        title: String,
        titleColor: Color = .primary,
        @ViewBuilder content: () -> Content
    ) {
        self.init(title: title, titleColor: titleColor, trailing: { EmptyView() }, content: content)
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

    func isSameDay(as other: Date, calendar: Calendar = .current) -> Bool {
        calendar.isDate(self, inSameDayAs: other)
    }
}
