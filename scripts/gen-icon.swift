// Generates packaging/icon-1024.png — squircle gradient + chinchilla mascot.
// Usage: swift scripts/gen-icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "packaging/icon-1024.png"

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// macOS-style rounded square with margin (icon grid ≈ 100px margin @1024).
let margin: CGFloat = 100
let rect = NSRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
let squircle = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)

let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.55, green: 0.35, blue: 0.95, alpha: 1),
    NSColor(calibratedRed: 0.30, green: 0.20, blue: 0.65, alpha: 1),
])!
gradient.draw(in: squircle, angle: -70)

// Soft inner highlight.
NSColor.white.withAlphaComponent(0.12).setFill()
let highlight = NSBezierPath(roundedRect: rect.insetBy(dx: 22, dy: 22), xRadius: 165, yRadius: 165)
highlight.fill()

func draw(_ text: String, fontSize: CGFloat, center: CGPoint) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: fontSize),
    ]
    let string = NSAttributedString(string: text, attributes: attrs)
    let bounds = string.boundingRect(with: NSSize(width: size, height: size))
    string.draw(at: NSPoint(x: center.x - bounds.width / 2, y: center.y - bounds.height / 2))
}

// Mascot + sparkle.
draw("🐭", fontSize: 470, center: CGPoint(x: size / 2, y: size / 2 - 20))
draw("✨", fontSize: 170, center: CGPoint(x: size / 2 + 235, y: size / 2 + 225))

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("could not render icon")
}
try png.write(to: URL(fileURLWithPath: outputPath))
print("Wrote \(outputPath)")
