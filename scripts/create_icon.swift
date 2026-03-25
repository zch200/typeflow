import AppKit

let iconsetPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/TypeFlow.iconset"
try? FileManager.default.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

let specs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for (name, size) in specs {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: s, height: s)
    let radius = s * 0.2237

    // Clip to rounded rect (macOS icon shape)
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()

    // Gradient background
    if let gradient = NSGradient(colors: [
        NSColor(red: 0.22, green: 0.42, blue: 0.96, alpha: 1.0),
        NSColor(red: 0.48, green: 0.28, blue: 0.88, alpha: 1.0),
    ]) {
        gradient.draw(in: rect, angle: -45)
    }

    // White mic symbol via SF Symbols (macOS 11+)
    if s >= 32,
       let symbol = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil),
       let configured = symbol.withSymbolConfiguration(
           NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .regular)
       )
    {
        let symSize = configured.size
        let symRect = NSRect(
            x: (s - symSize.width) / 2,
            y: (s - symSize.height) / 2,
            width: symSize.width,
            height: symSize.height
        )

        // Create white-tinted version
        let white = NSImage(size: symSize)
        white.lockFocus()
        configured.draw(in: NSRect(origin: .zero, size: symSize))
        NSColor.white.setFill()
        NSRect(origin: .zero, size: symSize).fill(using: .sourceAtop)
        white.unlockFocus()
        white.draw(in: symRect)
    } else {
        // Fallback for small sizes: draw "T" letter
        let fontSize = s * 0.6
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let text = NSAttributedString(string: "T", attributes: attrs)
        let textSize = text.size()
        text.draw(at: NSPoint(x: (s - textSize.width) / 2, y: (s - textSize.height) / 2))
    }

    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else { continue }

    let path = (iconsetPath as NSString).appendingPathComponent(name)
    try? (png as NSData).write(toFile: path, atomically: true)
}

print("Created iconset at \(iconsetPath)")
