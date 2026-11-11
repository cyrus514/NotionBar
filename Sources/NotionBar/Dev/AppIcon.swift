import AppKit
import SwiftUI

/// The app icon, drawn in code: a dark editor tile with a three-line checklist.
/// `NotionBar --make-icon <folder>` writes it as an `.iconset`; `scripts/make_icon.sh` turns that into `AppIcon.icns`.
struct AppIconView: View {
    var body: some View {
        // Drawn on a 1024 pt canvas, in the standard macOS icon shape (824 pt tile, rounded corners).
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x1C2330), Color(hex: 0x0D1117)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 185, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 6))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 24, x: 0, y: 14)

            VStack(alignment: .leading, spacing: 62) {
                line(done: true, width: 300, color: Tint.blue)
                line(done: true, width: 220, color: Tint.purple)
                line(done: false, width: 270, color: Tint.yellow)
            }
        }
        .frame(width: 1024, height: 1024)
    }

    private func line(done: Bool, width: CGFloat, color: Color) -> some View {
        HStack(spacing: 46) {
            ZStack {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(done ? Color(hex: 0x3FB950) : Color.clear)
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .strokeBorder(done ? Color(hex: 0x3FB950) : Color(hex: 0x8B949E), lineWidth: 22)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 92, weight: .black))
                        .foregroundStyle(Color(hex: 0x0D1117))
                }
            }
            .frame(width: 150, height: 150)

            RoundedRectangle(cornerRadius: 24)
                .fill(done ? Color(hex: 0x8B949E).opacity(0.55) : color)
                .frame(width: width, height: 48)
        }
    }
}

@MainActor
enum AppIcon {
    static func writeAndExit(to folder: String) {
        let iconset = URL(fileURLWithPath: folder).appendingPathComponent("AppIcon.iconset")
        do {
            try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
            // (points, scale) pairs macOS expects in an iconset.
            for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
                let pixels = CGFloat(points * scale)
                let renderer = ImageRenderer(content: AppIconView().scaleEffect(pixels / 1024).frame(width: pixels, height: pixels))
                renderer.scale = 1
                guard let image = renderer.cgImage else { throw CocoaError(.fileWriteUnknown) }
                let bitmap = NSBitmapImageRep(cgImage: image)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
                let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
                try png.write(to: iconset.appendingPathComponent(name))
            }
            print("wrote \(iconset.path)")
            exit(0)
        } catch {
            print("couldn't write the icon: \(error.localizedDescription)")
            exit(1)
        }
    }
}
