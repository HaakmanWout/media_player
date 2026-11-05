import AppKit

// Renders the 1024×1024 app icon: a music note radiating sound waves (music + podcasts).
// Usage: swift Tools/make_icon.swift <light.png> <dark.png>, then strip alpha (e.g. ffmpeg -pix_fmt rgb24)
// and copy into MediaPlayer/Assets.xcassets/AppIcon.appiconset as AppIcon.png / AppIcon-Dark.png.

let size: CGFloat = 1024

func render(dark: Bool, to path: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    let space = CGColorSpaceCreateDeviceRGB()

    // Background: diagonal gradient, the app's pink into violet (deep, near-black tones for dark mode).
    let colors: [CGColor] = dark
        ? [CGColor(red: 0.16, green: 0.05, blue: 0.10, alpha: 1), CGColor(red: 0.06, green: 0.03, blue: 0.12, alpha: 1)]
        : [CGColor(red: 1.00, green: 0.24, blue: 0.40, alpha: 1), CGColor(red: 0.47, green: 0.16, blue: 0.86, alpha: 1)]
    let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

    // Soft glow behind the note.
    let glow = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 1, green: 1, blue: 1, alpha: dark ? 0.10 : 0.22),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0),
    ] as CFArray, locations: [0, 1])!
    let center = CGPoint(x: size / 2, y: size / 2)
    ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: 420, options: [])

    // Sound waves: two arcs on each side, fading outward.
    let accent = dark ? NSColor(red: 1.0, green: 0.30, blue: 0.47, alpha: 1) : NSColor.white
    ctx.setLineCap(.round)
    for (index, radius) in [CGFloat(270), 365].enumerated() {
        ctx.setLineWidth(40)
        ctx.setStrokeColor(accent.withAlphaComponent(index == 0 ? 0.85 : 0.5).cgColor)
        for side in [0.0, CGFloat.pi] {
            ctx.addArc(center: center, radius: radius, startAngle: side - .pi / 5, endAngle: side + .pi / 5, clockwise: false)
            ctx.strokePath()
        }
    }

    // The note itself, from SF Symbols, centred in the waves.
    let config = NSImage.SymbolConfiguration(pointSize: 330, weight: .bold)
        .applying(.init(paletteColors: [dark ? accent : .white]))
    let note = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
    let noteSize = note.size
    // Shadow for depth.
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: CGColor(gray: 0, alpha: dark ? 0.5 : 0.25))
    note.draw(in: CGRect(x: center.x - noteSize.width / 2, y: center.y - noteSize.height / 2,
                         width: noteSize.width, height: noteSize.height))

    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

render(dark: false, to: CommandLine.arguments[1])
render(dark: true, to: CommandLine.arguments[2])
