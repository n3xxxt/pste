// Генератор иконки приложения: рисует squircle с градиентом и глифом планшета.
import AppKit

_ = NSApplication.shared

func makeIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let inset = size * 0.055
    let body = NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset),
                            xRadius: size * 0.2237, yRadius: size * 0.2237)

    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.45, green: 0.42, blue: 0.98, alpha: 1),
        NSColor(srgbRed: 0.72, green: 0.33, blue: 0.92, alpha: 1)
    ])!
    gradient.draw(in: body, angle: -90)

    let config = NSImage.SymbolConfiguration(pointSize: size * 0.46, weight: .semibold)
    if let symbol = NSImage(systemSymbolName: "list.clipboard.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let tinted = NSImage(size: symbol.size)
        tinted.lockFocus()
        symbol.draw(in: NSRect(origin: .zero, size: symbol.size))
        NSColor.white.set()
        NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
        tinted.unlockFocus()

        tinted.draw(in: NSRect(x: (size - symbol.size.width) / 2,
                               y: (size - symbol.size.height) / 2,
                               width: symbol.size.width,
                               height: symbol.size.height))
    }

    image.unlockFocus()
    return image
}

func writePNG(_ image: NSImage, side: Int, to url: URL) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return }
    rep.size = NSSize(width: side, height: side)
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: url)
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let variants: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png")
]

for (side, name) in variants {
    let image = makeIcon(size: CGFloat(side))
    writePNG(image, side: side, to: outputDirectory.appendingPathComponent(name))
}

print("icon variants written to \(outputDirectory.path)")
