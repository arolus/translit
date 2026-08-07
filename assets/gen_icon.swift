// AppIcon generator for Translit.
// Dark squircle, two keycaps — a blue "Я" and a light "A" — with swap arrows
// between them: the two layouts this tool switches between.
// Run: swift gen_icon.swift   → icon_1024.png (then sips/iconutil → .icns)
import AppKit

let size: CGFloat = 1024

func keycap(in rect: NSRect, fill: NSGradient, stroke: NSColor,
            letter: String, letterColor: NSColor) {
    let radius = rect.width * 0.22
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    // Soft drop shadow so the caps sit above the background.
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
    shadow.shadowBlurRadius = size * 0.025
    shadow.set()
    letterColor.withAlphaComponent(0.001).setFill() // shadow needs a fill pass
    path.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    fill.draw(in: path, angle: -90)
    path.lineWidth = size * 0.008
    stroke.setStroke()
    path.stroke()

    let font = NSFont.systemFont(ofSize: rect.height * 0.62, weight: .bold)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: letterColor]
    let text = NSAttributedString(string: letter, attributes: attrs)
    let bounds = text.boundingRect(with: rect.size, options: [.usesLineFragmentOrigin])
    text.draw(at: NSPoint(x: rect.midX - bounds.width / 2,
                          y: rect.midY - bounds.height / 2 - font.descender * 0.18))
}

func drawIcon() -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()

    // Background squircle — same dark family as the other dotfiles tools.
    let inset: CGFloat = size * 0.098
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.185, yRadius: size * 0.185)
    let top = NSColor(calibratedRed: 0.16, green: 0.19, blue: 0.30, alpha: 1)
    let bottom = NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.14, alpha: 1)
    NSGradient(starting: top, ending: bottom)!.draw(in: path, angle: -90)
    path.lineWidth = size * 0.006
    NSColor(white: 1, alpha: 0.10).setStroke()
    path.stroke()

    // Two keycaps, the right one slightly lower — mid-swap.
    let capSize = size * 0.34
    let gap = size * 0.055
    let leftX = size / 2 - capSize - gap / 2
    let ruFill = NSGradient(
        starting: NSColor(calibratedRed: 0.36, green: 0.56, blue: 1.00, alpha: 1),
        ending: NSColor(calibratedRed: 0.20, green: 0.38, blue: 0.90, alpha: 1))!
    let enFill = NSGradient(
        starting: NSColor(calibratedRed: 0.98, green: 0.98, blue: 1.00, alpha: 1),
        ending: NSColor(calibratedRed: 0.82, green: 0.84, blue: 0.90, alpha: 1))!

    keycap(in: NSRect(x: leftX, y: size * 0.46, width: capSize, height: capSize),
           fill: ruFill, stroke: NSColor(white: 1, alpha: 0.25),
           letter: "Я", letterColor: .white)
    keycap(in: NSRect(x: size / 2 + gap / 2, y: size * 0.38, width: capSize, height: capSize),
           fill: enFill, stroke: NSColor(white: 0, alpha: 0.15),
           letter: "A", letterColor: NSColor(calibratedRed: 0.13, green: 0.15, blue: 0.22, alpha: 1))

    // Swap arrows beneath the caps.
    let cfg = NSImage.SymbolConfiguration(pointSize: size * 0.16, weight: .semibold)
        .applying(.init(paletteColors: [NSColor(calibratedRed: 0.55, green: 0.70, blue: 1.0, alpha: 1)]))
    if let sym = NSImage(systemSymbolName: "arrow.left.arrow.right",
                         accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let s = sym.size
        let scale = (size * 0.20) / max(s.width, s.height)
        let w = s.width * scale, h = s.height * scale
        sym.draw(in: NSRect(x: (size - w) / 2, y: size * 0.175, width: w, height: h))
    }

    img.unlockFocus()
    return img
}

let icon = drawIcon()
let dir = FileManager.default.currentDirectoryPath
guard let tiff = icon.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
    fatalError("no bitmap rep")
}
rep.size = NSSize(width: size, height: size)
try! rep.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: dir + "/icon_1024.png"))
print("OK: icon_1024.png")
