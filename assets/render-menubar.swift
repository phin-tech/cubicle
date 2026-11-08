import AppKit

let size = 72
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size,
    pixelsHigh: size,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: size, height: size).fill()

NSColor.black.setFill()
NSColor.black.setStroke()

// One-color top-down cubicle grid. The filled lower-right cell is the
// active Space; the other three remain open, like partitioned work bays.
let outer = NSBezierPath(roundedRect: NSRect(x: 8, y: 8, width: 56, height: 56), xRadius: 8, yRadius: 8)
outer.lineWidth = 7
outer.stroke()

let vertical = NSBezierPath()
vertical.move(to: NSPoint(x: 36, y: 10))
vertical.line(to: NSPoint(x: 36, y: 62))
vertical.lineWidth = 7
vertical.stroke()

let horizontal = NSBezierPath()
horizontal.move(to: NSPoint(x: 10, y: 36))
horizontal.line(to: NSPoint(x: 62, y: 36))
horizontal.lineWidth = 7
horizontal.stroke()

NSBezierPath(roundedRect: NSRect(x: 40, y: 12, width: 20, height: 20), xRadius: 3, yRadius: 3).fill()

NSGraphicsContext.restoreGraphicsState()

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "menubar-template.png")
try rep.representation(using: .png, properties: [:])!.write(to: output)
