import AppKit
import Foundation

let dest = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let rect = NSRect(x: 0, y: 0, width: size, height: size)
let radius: CGFloat = 228
let path = NSBezierPath(roundedRect: rect.insetBy(dx: 36, dy: 36), xRadius: radius, yRadius: radius)
NSColor(calibratedRed: 0.239, green: 0.478, blue: 0.416, alpha: 1).setFill()
path.fill()

let inner = NSBezierPath(roundedRect: rect.insetBy(dx: 150, dy: 150), xRadius: 160, yRadius: 160)
NSColor(calibratedRed: 0.965, green: 0.945, blue: 0.918, alpha: 0.16).setFill()
inner.fill()

func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ color: NSColor) {
    color.setFill()
    NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: r * 2, height: r * 2)).fill()
}
circle(340, 430, 92, NSColor(calibratedRed: 0.965, green: 0.945, blue: 0.918, alpha: 1))
circle(684, 590, 92, NSColor(calibratedRed: 0.769, green: 0.314, blue: 0.165, alpha: 1))

let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 430, y: 470))
arrow.curve(to: NSPoint(x: 600, y: 560), controlPoint1: NSPoint(x: 500, y: 430), controlPoint2: NSPoint(x: 530, y: 620))
NSColor(calibratedRed: 0.965, green: 0.945, blue: 0.918, alpha: 1).setStroke()
arrow.lineWidth = 36
arrow.lineCapStyle = .round
arrow.stroke()

image.unlockFocus()
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("图标生成失败\n", stderr)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: dest))
