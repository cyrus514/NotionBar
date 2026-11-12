// Draws the picture behind the icons in the installer disk image's window.
//
//   swiftc -O scripts/dmg_background.swift -o .build/dmg-background
//   .build/dmg-background Support/dmg             → background.png and background@2x.png
//   .build/dmg-background Support/dmg <folder>    → also a mock-up of the window, light and dark
//
// `scripts/make_dmg.sh` puts the icons where `Layout` says. Change the two together.
import AppKit

enum Layout {
    /// The window's content area, in points.
    static let window = CGSize(width: 660, height: 400)
    /// The picture is a little larger than the window, so no bare edge shows if Finder's title bar is a
    /// different height than expected.
    static let canvas = CGSize(width: 700, height: 460)
    static let iconSize: CGFloat = 128
    /// Centers of the two icons.
    static let app = CGPoint(x: 202, y: 200)
    static let applications = CGPoint(x: 502, y: 200)

    /// The picture is laid out like a file in an editor: numbered lines beside a gutter.
    static let gutter: CGFloat = 44
    static let lineHeight: CGFloat = 22
    static let firstLine: CGFloat = 16
    static func top(ofLine number: Int) -> CGFloat { firstLine + CGFloat(number - 1) * lineHeight }
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func mono(_ size: CGFloat, bold: Bool = false) -> NSFont {
    NSFont(name: bold ? "Menlo-Bold" : "Menlo-Regular", size: size)
        ?? .monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
}

func write(_ parts: [(String, NSColor)], at point: CGPoint, size: CGFloat = 12) {
    let line = NSMutableAttributedString()
    for (string, tint) in parts {
        line.append(NSAttributedString(string: string, attributes: [.font: mono(size), .foregroundColor: tint]))
    }
    line.draw(at: point)
}

/// The installer as one of NotionBar's own task lists, open in an editor: the steps already behind
/// you are ticked, "drag NotionBar into Applications" is the one that's due now, and the two icons sit
/// under it.
///
/// Finder draws the icon names itself, black in light mode and white in dark mode, so each icon sits
/// on a mid-grey tile that both can be read against.
func drawBackground() {
    let comment = color(0x8B949E), plain = color(0xC9D1D9), dim = color(0x6E7681), faint = color(0x3D444D)
    let green = color(0x3FB950), blue = color(0x3B8EEA), purple = color(0xA371F7), yellow = color(0xD4A72C)
    let full = CGRect(origin: .zero, size: Layout.canvas)
    let textX = Layout.gutter + 34

    // Editor background, with a faint grid of dots and a glow behind each icon.
    NSGradient(starting: color(0x1C2330), ending: color(0x0D1117))!.draw(in: full, angle: 90)
    color(0xFFFFFF, 0.05).setFill()
    for x in stride(from: Layout.gutter + 18, to: full.width, by: 22) {
        for y in stride(from: CGFloat(12), to: full.height, by: 22) {
            NSBezierPath(ovalIn: CGRect(x: x, y: y, width: 1.5, height: 1.5)).fill()
        }
    }
    for (center, tint) in [(Layout.app, blue), (Layout.applications, purple)] {
        // Fades to nothing by its edge, so no circle shows.
        NSGradient(colors: [tint.withAlphaComponent(0.30), tint.withAlphaComponent(0.10), tint.withAlphaComponent(0)],
                   atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
            .draw(fromCenter: center, radius: 0, toCenter: center, radius: 210, options: [])
    }

    // The gutter: line numbers, the current line's a little brighter.
    color(0x0D1117, 0.55).setFill()
    CGRect(x: 0, y: 0, width: Layout.gutter, height: full.height).fill()
    color(0xFFFFFF, 0.07).setFill()
    CGRect(x: Layout.gutter, y: 0, width: 1, height: full.height).fill()
    let currentLine = 4
    for number in 1...21 {
        let label = NSAttributedString(string: "\(number)", attributes: [
            .font: mono(10.5), .foregroundColor: number == currentLine ? plain : faint])
        label.draw(at: CGPoint(x: Layout.gutter - 12 - label.size().width, y: Layout.top(ofLine: number) + 1.5))
    }

    // One row of the list: a checkbox drawn like the ones in the app icon, then the text.
    func row(_ line: Int, done: Bool = false, current: Bool = false, _ text: String) {
        let y = Layout.top(ofLine: line)
        if current {
            blue.withAlphaComponent(0.20).setFill()
            CGRect(x: Layout.gutter + 1, y: y - 4, width: full.width, height: Layout.lineHeight).fill()
            blue.setFill()
            CGRect(x: Layout.gutter + 1, y: y - 4, width: 2.5, height: Layout.lineHeight).fill()
        }
        let box = CGRect(x: Layout.gutter + 14, y: y + 1.5, width: 12, height: 12)
        let outline = NSBezierPath(roundedRect: box.insetBy(dx: 0.75, dy: 0.75), xRadius: 3, yRadius: 3)
        if done {
            green.setFill()
            NSBezierPath(roundedRect: box, xRadius: 3.5, yRadius: 3.5).fill()
            let tick = NSBezierPath()
            tick.move(to: CGPoint(x: box.minX + 3, y: box.midY + 0.3))
            tick.line(to: CGPoint(x: box.minX + 5.2, y: box.maxY - 3.3))
            tick.line(to: CGPoint(x: box.maxX - 2.8, y: box.minY + 3.4))
            tick.lineWidth = 1.7
            tick.lineCapStyle = .round
            tick.lineJoinStyle = .round
            color(0x0D1117).setStroke()
            tick.stroke()
        } else {
            outline.lineWidth = 1.5
            (current ? yellow : comment).setStroke()
            outline.stroke()
        }
        var attributes: [NSAttributedString.Key: Any] = [.font: mono(12, bold: current), .foregroundColor: done ? dim : plain]
        if done {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attributes[.strikethroughColor] = dim
        }
        NSAttributedString(string: text, attributes: attributes).draw(at: CGPoint(x: textX, y: y))
    }

    // A small rounded tag at the right end of a line, like the app's "due" tags.
    func tag(_ line: Int, _ text: String, _ tint: NSColor) {
        let label = NSAttributedString(string: text, attributes: [.font: mono(10.5, bold: true), .foregroundColor: tint])
        let size = label.size()
        let pill = CGRect(x: Layout.window.width - 22 - size.width - 14, y: Layout.top(ofLine: line) - 1.5,
                          width: size.width + 14, height: 17)
        tint.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 8.5, yRadius: 8.5).fill()
        label.draw(at: CGPoint(x: pill.minX + 7, y: pill.minY + (pill.height - size.height) / 2))
    }

    // Line 1: the file's name, and how far along you are.
    write([("// install.todo", comment)], at: CGPoint(x: Layout.gutter + 14, y: Layout.top(ofLine: 1)))
    let segment = CGSize(width: 16, height: 5)
    for index in 0..<4 {
        (index < 2 ? green : color(0xFFFFFF, 0.14)).setFill()
        let x = Layout.window.width - 22 - CGFloat(4 - index) * (segment.width + 4) + 4
        NSBezierPath(roundedRect: CGRect(origin: CGPoint(x: x, y: Layout.top(ofLine: 1) + 5), size: segment),
                     xRadius: 2.5, yRadius: 2.5).fill()
    }
    let progress = NSAttributedString(string: "2/4", attributes: [.font: mono(10.5), .foregroundColor: comment])
    progress.draw(at: CGPoint(x: Layout.window.width - 22 - 4 * (segment.width + 4) - progress.size().width - 6,
                              y: Layout.top(ofLine: 1) + 1))

    row(2, done: true, "download NotionBar")
    row(3, done: true, "open this disk image")
    row(currentLine, current: true, "drag NotionBar into Applications")
    tag(currentLine, "due now", yellow)

    // The two icons' tiles. The one you drop onto has a dashed outline.
    for center in [Layout.app, Layout.applications] {
        let tile = CGRect(x: center.x - 88, y: center.y - 80, width: 176, height: 184)
        NSGradient(starting: color(0x737D89), ending: color(0x656E7A))!
            .draw(in: NSBezierPath(roundedRect: tile, xRadius: 22, yRadius: 22), angle: 90)
        let edge = NSBezierPath(roundedRect: tile.insetBy(dx: 0.5, dy: 0.5), xRadius: 21.5, yRadius: 21.5)
        edge.lineWidth = 1
        color(0xFFFFFF, 0.20).setStroke()
        edge.stroke()
        if center == Layout.applications {
            let drop = NSBezierPath(roundedRect: tile.insetBy(dx: 7, dy: 7), xRadius: 16, yRadius: 16)
            drop.lineWidth = 1.5
            drop.setLineDash([6, 5], count: 2, phase: 0)
            color(0xFFFFFF, 0.42).setStroke()
            drop.stroke()
        }
    }

    // Between them: "$ mv" and three chevrons, each brighter than the last.
    let middle = (Layout.app.x + Layout.applications.x) / 2, y = Layout.app.y
    let command = NSMutableAttributedString(string: "$ ", attributes: [.font: mono(12, bold: true), .foregroundColor: green])
    command.append(NSAttributedString(string: "mv", attributes: [.font: mono(12, bold: true), .foregroundColor: plain]))
    command.draw(at: CGPoint(x: middle - command.size().width / 2, y: y - 40))
    for (index, strength) in [0.35, 0.65, 1.0].enumerated() {
        let x = middle + CGFloat(index - 1) * 20
        let chevron = NSBezierPath()
        chevron.move(to: CGPoint(x: x - 5, y: y - 10))
        chevron.line(to: CGPoint(x: x + 5, y: y))
        chevron.line(to: CGPoint(x: x - 5, y: y + 10))
        chevron.lineWidth = 3
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        (blue.blended(withFraction: CGFloat(index) / 2, of: purple) ?? blue).withAlphaComponent(strength).setStroke()
        chevron.stroke()
    }

    // What's left after the drag. macOS blocks the first launch of an app that isn't notarized, and a
    // menu bar app has no Dock icon, so say both.
    row(15, "allow the first launch")
    write([("// System Settings → Privacy & Security → Open Anyway", comment)],
          at: CGPoint(x: textX, y: Layout.top(ofLine: 16)))
    let last = "find it in your menu bar, not the Dock"
    row(17, last)
    let width = NSAttributedString(string: last + " ", attributes: [.font: mono(12)]).size().width
    write([("↗", blue)], at: CGPoint(x: textX + width, y: Layout.top(ofLine: 17) - 1.5), size: 14)
}

/// Roughly what Finder shows: the picture, the two icons, and their names in Finder's own color.
func drawMock(dark: Bool) {
    drawBackground()
    func icon(_ image: NSImage, _ center: CGPoint, _ name: String) {
        let half = Layout.iconSize / 2
        image.draw(in: CGRect(x: center.x - half, y: center.y - half, width: Layout.iconSize, height: Layout.iconSize),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let label = NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: dark ? NSColor.white : NSColor.black])
        label.draw(at: CGPoint(x: center.x - label.size().width / 2, y: center.y + half + 5))
    }
    if let app = NSImage(contentsOfFile: "Sources/NotionBar/Resources/AppIcon.icns") { icon(app, Layout.app, "NotionBar") }
    icon(NSWorkspace.shared.icon(forFile: "/Applications"), Layout.applications, "Applications")
}

/// Draws with the origin at the top left, in points, onto `scale` pixels per point.
func png(size: CGSize, scale: Int, _ draw: () -> Void) -> Data {
    let width = Int(size.width) * scale, height = Int(size.height) * scale
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    bitmap.size = size
    return bitmap.representation(using: .png, properties: [:])!
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let folder = arguments.first else {
    print("usage: dmg-background <folder> [<mock-up folder>]")
    exit(2)
}
do {
    let out = URL(fileURLWithPath: folder)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    try png(size: Layout.canvas, scale: 1, drawBackground).write(to: out.appendingPathComponent("background.png"))
    try png(size: Layout.canvas, scale: 2, drawBackground).write(to: out.appendingPathComponent("background@2x.png"))
    print("wrote \(folder)/background.png and background@2x.png")
    if arguments.count > 1 {
        let mock = URL(fileURLWithPath: arguments[1])
        try FileManager.default.createDirectory(at: mock, withIntermediateDirectories: true)
        try png(size: Layout.window, scale: 2) { drawMock(dark: false) }.write(to: mock.appendingPathComponent("window-light.png"))
        try png(size: Layout.window, scale: 2) { drawMock(dark: true) }.write(to: mock.appendingPathComponent("window-dark.png"))
        print("wrote \(arguments[1])/window-light.png and window-dark.png")
    }
} catch {
    print("couldn't write the picture: \(error.localizedDescription)")
    exit(1)
}
