// Run from the repository root: swift Tools/generate-alarm-control-symbols.swift
import CoreGraphics
import Foundation

func line(_ start: CGPoint, _ end: CGPoint, width: CGFloat) -> CGPath {
    let path = CGMutablePath()
    path.move(to: start)
    path.addLine(to: end)
    return path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
}

enum State: String, CaseIterable {
    case on = "PillsAlarmsOn"
    case off = "PillsAlarmsOff"
    case pending = "PillsAlarmsPending"
}

func paths(state: State) -> [CGPath] {
    let tablet = CGPath(ellipseIn: CGRect(x: 1, y: 3, width: 25, height: 25), transform: nil)
    // The tablet score slopes up; the muted bell's slash slopes down.
    let score = line(CGPoint(x: 7.49, y: 21.51), CGPoint(x: 19.51, y: 9.49), width: 2)
    let badge = CGPath(roundedRect: CGRect(x: 18, y: 17, width: 18, height: 18),
                       cornerWidth: 4, cornerHeight: 4, transform: nil)
    let bell = CGMutablePath()
    bell.move(to: CGPoint(x: 27, y: 20))
    bell.addCurve(to: CGPoint(x: 22.8, y: 24.3), control1: CGPoint(x: 24.5, y: 20), control2: CGPoint(x: 22.8, y: 21.8))
    bell.addLine(to: CGPoint(x: 22.8, y: 26.3))
    bell.addCurve(to: CGPoint(x: 21.5, y: 29.6), control1: CGPoint(x: 22.8, y: 27.8), control2: CGPoint(x: 22.2, y: 28.8))
    bell.addLine(to: CGPoint(x: 32.5, y: 29.6))
    bell.addCurve(to: CGPoint(x: 31.2, y: 26.3), control1: CGPoint(x: 31.8, y: 28.8), control2: CGPoint(x: 31.2, y: 27.8))
    bell.addLine(to: CGPoint(x: 31.2, y: 24.3))
    bell.addCurve(to: CGPoint(x: 27, y: 20), control1: CGPoint(x: 31.2, y: 21.8), control2: CGPoint(x: 29.5, y: 20))
    bell.closeSubpath()
    bell.move(to: CGPoint(x: 25.7, y: 31.8))
    bell.addCurve(to: CGPoint(x: 28.3, y: 31.8), control1: CGPoint(x: 26.2, y: 33), control2: CGPoint(x: 27.8, y: 33))
    let outline = bell.copy(strokingWithWidth: 1.5, lineCap: .round, lineJoin: .round, miterLimit: 10)
    let body = tablet.subtracting(score).subtracting(badge)
    if state == .on { return [body, outline] }
    if state == .pending {
        let question = CGMutablePath()
        question.move(to: CGPoint(x: 25.7, y: 22))
        question.addCurve(to: CGPoint(x: 28.6, y: 19.9), control1: CGPoint(x: 25.9, y: 20.6), control2: CGPoint(x: 27, y: 19.9))
        question.addCurve(to: CGPoint(x: 31.3, y: 22.3), control1: CGPoint(x: 30.3, y: 19.9), control2: CGPoint(x: 31.3, y: 20.8))
        question.addCurve(to: CGPoint(x: 29.6, y: 24.8), control1: CGPoint(x: 31.3, y: 23.5), control2: CGPoint(x: 30.5, y: 24.1))
        question.addCurve(to: CGPoint(x: 28.6, y: 26.8), control1: CGPoint(x: 28.8, y: 25.4), control2: CGPoint(x: 28.6, y: 25.9))
        let mark = question.copy(strokingWithWidth: 1.6, lineCap: .round, lineJoin: .round, miterLimit: 10)
        let clearance = question.copy(strokingWithWidth: 3.6, lineCap: .round, lineJoin: .round, miterLimit: 10)
        let dot = CGPath(ellipseIn: CGRect(x: 27.7, y: 28.7, width: 1.8, height: 1.8), transform: nil)
        let dotClearance = CGPath(ellipseIn: CGRect(x: 26.7, y: 27.7, width: 3.8, height: 3.8), transform: nil)
        return [body, outline.subtracting(clearance).subtracting(dotClearance), mark, dot]
    }
    let start = CGPoint(x: 20.5, y: 19.5)
    let end = CGPoint(x: 32.45, y: 31.45)
    return [body, outline.subtracting(line(start, end, width: 3.2)), line(start, end, width: 1.6)]
}

func number(_ value: CGFloat) -> String {
    String(format: "%.7f", locale: Locale(identifier: "en_US_POSIX"), Double(value))
}

func svgPath(_ path: CGPath) -> String {
    var commands: [String] = []
    path.applyWithBlock { pointer in
        let element = pointer.pointee
        func point(_ index: Int) -> String {
            "\(number(element.points[index].x)) \(number(element.points[index].y))"
        }
        switch element.type {
        case .moveToPoint: commands.append("M\(point(0))")
        case .addLineToPoint: commands.append("L\(point(0))")
        case .addQuadCurveToPoint: commands.append("Q\(point(0)) \(point(1))")
        case .addCurveToPoint: commands.append("C\(point(0)) \(point(1)) \(point(2))")
        case .closeSubpath: commands.append("Z")
        @unknown default: fatalError("Unsupported path element")
        }
    }
    return commands.joined(separator: " ")
}

let catalog = URL(fileURLWithPath: "PillsAlarmControls/Assets.xcassets", isDirectory: true)
for state in State.allCases {
    let name = state.rawValue
    let outlines = paths(state: state).map { "      <path d=\"\(svgPath($0))\"/>" }.joined(separator: "\n")
    // Control Center requests its own weight and scale; export every static slot.
    let weights = ["Ultralight", "Thin", "Light", "Regular", "Medium", "Semibold", "Bold", "Heavy", "Black"]
    let scales: [(String, CGFloat)] = [("S", 0.783), ("M", 1), ("L", 1.29)]
    var guides: [String] = []
    var variants: [String] = []
    for (row, scale) in scales.enumerated() {
        let (suffix, factor) = scale
        let baseline = CGFloat(row * 160 + 100)
        let capline = baseline - 70.46 * factor
        guides.append("    <line id=\"Baseline-\(suffix)\" x1=\"0\" y1=\"\(number(baseline))\" x2=\"1440\" y2=\"\(number(baseline))\"/>")
        guides.append("    <line id=\"Capline-\(suffix)\" x1=\"0\" y1=\"\(number(capline))\" x2=\"1440\" y2=\"\(number(capline))\"/>")
        for (column, weight) in weights.enumerated() {
            let variant = "\(weight)-\(suffix)"
            let left = CGFloat(column * 160)
            // Optical margins are centered on the tablet; the bell overhangs on the right.
            let leading = left
            let right = left + (2 * 13.5 * 3) * factor
            let top = baseline - (15.5 * 3 + 70.46 / 2) * factor
            guides.append("    <line id=\"left-margin-\(variant)\" x1=\"\(number(leading))\" y1=\"0\" x2=\"\(number(leading))\" y2=\"480\"/>")
            guides.append("    <line id=\"right-margin-\(variant)\" x1=\"\(number(right))\" y1=\"0\" x2=\"\(number(right))\" y2=\"480\"/>")
            variants.append("""
                <g id="\(variant)" transform="translate(\(number(left)) \(number(top))) scale(\(number(3 * factor)))" fill="black">
            \(outlines)
                </g>
            """)
        }
    }
    let source = """
    <?xml version="1.0" encoding="utf-8"?>
    <!-- Generated by Tools/generate-alarm-control-symbols.swift. -->
    <svg xmlns="http://www.w3.org/2000/svg" width="1440" height="480" viewBox="0 0 1440 480">
      <g id="Notes"><text id="template-version">Template v.3.0</text></g>
      <g id="Guides">
    \(guides.joined(separator: "\n"))
      </g>
      <g id="Symbols">
    \(variants.joined(separator: "\n"))
      </g>
    </svg>
    """
    let destination = catalog.appendingPathComponent("\(name).symbolset/\(name).svg")
    try source.appending("\n").write(to: destination, atomically: true, encoding: .utf8)
    print(destination.path)
}
