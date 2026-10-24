// Renders the OpenThock app icon: swift scripts/make-icon.swift <out.png>
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: nil)!
}

// Background tile (macOS icon grid: 824pt body, 100pt margin).
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
ctx.addPath(tilePath); ctx.setFillColor(color(0xF59E0B)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
ctx.drawLinearGradient(gradient([color(0xFDBA74), color(0xEA580C)]),
                       start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

// Sound waves on both sides.
ctx.setLineCap(.round)
for (i, r) in [CGFloat(250), 320, 390].enumerated() {
    ctx.setStrokeColor(color(0xFFF7ED, 0.55 - CGFloat(i) * 0.15))
    ctx.setLineWidth(26)
    for side in [0.0, CGFloat.pi] {
        ctx.addArc(center: CGPoint(x: 512, y: 470), radius: r, startAngle: side - 0.42, endAngle: side + 0.42, clockwise: false)
        ctx.strokePath()
    }
}

// Keycap: skirt, then dished top.
let skirt = CGRect(x: 322, y: 300, width: 380, height: 360)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -26), blur: 40, color: color(0x7C2D12, 0.55))
ctx.addPath(CGPath(roundedRect: skirt, cornerWidth: 70, cornerHeight: 70, transform: nil))
ctx.setFillColor(color(0x292524)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: skirt, cornerWidth: 70, cornerHeight: 70, transform: nil)); ctx.clip()
ctx.drawLinearGradient(gradient([color(0x57534E), color(0x1C1917)]),
                       start: CGPoint(x: 512, y: 660), end: CGPoint(x: 512, y: 300), options: [])
ctx.restoreGState()

let top = CGRect(x: 372, y: 380, width: 280, height: 250)
ctx.addPath(CGPath(roundedRect: top, cornerWidth: 48, cornerHeight: 48, transform: nil))
ctx.saveGState(); ctx.clip()
ctx.drawLinearGradient(gradient([color(0x78716C), color(0x44403C)]),
                       start: CGPoint(x: 512, y: 630), end: CGPoint(x: 512, y: 380), options: [])
ctx.restoreGState()
// Highlight along the top edge of the cap.
ctx.setStrokeColor(color(0xFFFFFF, 0.18)); ctx.setLineWidth(6)
ctx.addPath(CGPath(roundedRect: top.insetBy(dx: 3, dy: 3), cornerWidth: 45, cornerHeight: 45, transform: nil)); ctx.strokePath()
// Legend: a small orange bar like a homing bump.
ctx.addPath(CGPath(roundedRect: CGRect(x: 467, y: 440, width: 90, height: 18), cornerWidth: 9, cornerHeight: 9, transform: nil))
ctx.setFillColor(color(0xFB923C)); ctx.fillPath()
ctx.restoreGState()

image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
