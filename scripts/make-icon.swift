// Draws the LilaMD app icon (1024×1024 PNG): lilac squircle with a white "M↓" markdown mark.
// Usage: swift scripts/make-icon.swift <out.png>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "icon_1024.png")
let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: 824×824 body centred on the 1024 canvas, corner radius ≈ 185.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor(white: 0, alpha: 0.28).cgColor)
ctx.addPath(squircle)
ctx.setFillColor(NSColor(srgbRed: 0.55, green: 0.38, blue: 0.86, alpha: 1).cgColor)
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [NSColor(srgbRed: 0.80, green: 0.68, blue: 0.98, alpha: 1).cgColor,
                                   NSColor(srgbRed: 0.49, green: 0.31, blue: 0.84, alpha: 1).cgColor] as CFArray,
                          locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
ctx.restoreGState()

// Markdown mark: rounded frame, "M", down arrow.
let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1).cgColor
let frame = CGRect(x: 212, y: 332, width: 600, height: 360)
ctx.addPath(CGPath(roundedRect: frame, cornerWidth: 64, cornerHeight: 64, transform: nil))
ctx.setStrokeColor(white)
ctx.setLineWidth(40)
ctx.strokePath()

// "M" as a stroked polyline so it stays crisp at 16 px.
ctx.setLineWidth(56)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.move(to: CGPoint(x: 312, y: 412))
ctx.addLine(to: CGPoint(x: 312, y: 612))
ctx.addLine(to: CGPoint(x: 412, y: 502))
ctx.addLine(to: CGPoint(x: 512, y: 612))
ctx.addLine(to: CGPoint(x: 512, y: 412))
ctx.strokePath()

// Down arrow: shaft + filled head.
ctx.move(to: CGPoint(x: 660, y: 612))
ctx.addLine(to: CGPoint(x: 660, y: 500))
ctx.strokePath()
ctx.setFillColor(white)
ctx.move(to: CGPoint(x: 590, y: 492))
ctx.addLine(to: CGPoint(x: 730, y: 492))
ctx.addLine(to: CGPoint(x: 660, y: 400))
ctx.closePath()
ctx.fillPath()

NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: out)
print(out.path)
