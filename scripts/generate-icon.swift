import AppKit

let outputURL = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources/Cadence-1024.png")
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)

image.lockFocus()
NSColor.clear.setFill()
NSRect(origin: .zero, size: size).fill()

let tileRect = NSRect(x: 72, y: 72, width: 880, height: 880)
let tile = NSBezierPath(roundedRect: tileRect, xRadius: 214, yRadius: 214)

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
shadow.shadowBlurRadius = 38
shadow.shadowOffset = NSSize(width: 0, height: -18)
shadow.set()
NSColor(calibratedRed: 0.76, green: 0.93, blue: 0.42, alpha: 1).setFill()
tile.fill()
NSGraphicsContext.restoreGraphicsState()

let highlight = NSBezierPath(roundedRect: tileRect.insetBy(dx: 2, dy: 2), xRadius: 212, yRadius: 212)
NSColor.white.withAlphaComponent(0.18).setStroke()
highlight.lineWidth = 4
highlight.stroke()

let heights: [CGFloat] = [220, 350, 460, 330, 205]
let widths: CGFloat = 54
let gap: CGFloat = 42
let total = widths * CGFloat(heights.count) + gap * CGFloat(heights.count - 1)
let startX = (1024 - total) / 2

NSColor(calibratedRed: 0.095, green: 0.098, blue: 0.09, alpha: 1).setFill()
for (index, height) in heights.enumerated() {
    let x = startX + CGFloat(index) * (widths + gap)
    let rect = NSRect(x: x, y: 512 - height / 2, width: widths, height: height)
    NSBezierPath(roundedRect: rect, xRadius: widths / 2, yRadius: widths / 2).fill()
}

image.unlockFocus()
guard let data = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: data),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Unable to render Cadence icon")
}
try png.write(to: outputURL)
