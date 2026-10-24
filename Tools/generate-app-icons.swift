// Run from the repository root: swift Tools/generate-app-icons.swift [--check]
import AppKit
import ImageIO
import UniformTypeIdentifiers

struct IconCatalog: Decodable {
    struct Image: Decodable {
        let filename: String
        let size: String
        let scale: String

        var pixels: Int {
            get throws {
                guard let dimension = size.split(separator: "x").first, let points = Int(dimension),
                      let multiplier = Int(scale.dropLast()), points > 0, multiplier > 0 else {
                    throw IconError.invalidSize(filename)
                }
                return points * multiplier
            }
        }
    }
    let images: [Image]
}

enum IconError: Error {
    case invalidSize(String)
    case renderingFailed
    case validationFailed(String)
}

let catalog = URL(fileURLWithPath: "PillsAlarm/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
let manifest = try JSONDecoder().decode(IconCatalog.self, from: Data(contentsOf: catalog.appendingPathComponent("Contents.json")))
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func context(size: Int) throws -> CGContext {
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: size * 4, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
        throw IconError.renderingFailed
    }
    return context
}

func renderMaster() throws -> CGImage {
    let context = try context(size: 1024)
    let colors = [[18.0, 126, 176], [38.0, 206, 128]].map { components in
        CGColor(colorSpace: colorSpace, components: components.map { CGFloat($0 / 255) } + [1])!
    }
    guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: [0, 1]) else {
        throw IconError.renderingFailed
    }
    context.drawLinearGradient(gradient, start: CGPoint(x: 0.5, y: 1023.5),
                               end: CGPoint(x: 1023.5, y: 0.5), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    // Match the tablet and score geometry in generate-alarm-control-symbols.swift, without the bell badge.
    let tablet = CGPath(ellipseIn: CGRect(x: 1, y: 3, width: 25, height: 25), transform: nil)
    let score = CGMutablePath()
    score.move(to: CGPoint(x: 7.49, y: 21.51))
    score.addLine(to: CGPoint(x: 19.51, y: 9.49))
    let groove = score.copy(strokingWithWidth: 2, lineCap: .round, lineJoin: .round, miterLimit: 10)
    context.translateBy(x: 512, y: 512)
    context.scaleBy(x: 432 / 25.0, y: -432 / 25.0)
    context.translateBy(x: -13.5, y: -15.5)
    context.setFillColor(CGColor(colorSpace: colorSpace, components: [248 / 255.0, 252 / 255.0, 252 / 255.0, 1])!)
    context.addPath(tablet.subtracting(groove))
    context.fillPath()
    guard let image = context.makeImage() else { throw IconError.renderingFailed }
    return image
}

func write(_ master: CGImage, entry: IconCatalog.Image) throws {
    let pixels = try entry.pixels
    let context = try context(size: pixels)
    context.interpolationQuality = .high
    context.draw(master, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    let url = catalog.appendingPathComponent(entry.filename)
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw IconError.renderingFailed
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw IconError.renderingFailed }
}

func validate() throws {
    for entry in manifest.images {
        let url = catalog.appendingPathComponent(entry.filename)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == (try entry.pixels), image.height == (try entry.pixels),
              [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo) else {
            throw IconError.validationFailed(entry.filename)
        }
    }
    guard let master = NSBitmapImageRep(data: try Data(contentsOf: catalog.appendingPathComponent("AppIcon-1024.png"))) else {
        throw IconError.validationFailed("Master image")
    }
    func isTablet(_ x: Int, _ y: Int) -> Bool {
        var pixel = [UInt](repeating: 0, count: 4)
        master.getPixel(&pixel, atX: x, y: y)
        return pixel[0] > 240 && pixel[1] > 240 && pixel[2] > 240
    }
    let horizontal = (0..<1024).filter { isTablet($0, 512) }
    let vertical = (0..<1024).filter { isTablet(512, $0) }
    guard let left = horizontal.first, let right = horizontal.last,
          let top = vertical.first, let bottom = vertical.last,
          abs((left + right) - 1023) <= 2, abs((top + bottom) - 1023) <= 2,
          abs((right - left) - (bottom - top)) <= 1,
          isTablet(435, 435), isTablet(589, 589),
          !isTablet(448, 576), !isTablet(576, 448), !isTablet(512, 512),
          !isTablet(339, 339), !isTablet(685, 685) else {
        throw IconError.validationFailed("Tablet centering, circle, or score direction")
    }
    print("Validated \(manifest.images.count) opaque app icons; centered round tablet and matching diagonal score.")
}

if !CommandLine.arguments.contains("--check") {
    let master = try renderMaster()
    for entry in manifest.images { try write(master, entry: entry) }
}
try validate()
