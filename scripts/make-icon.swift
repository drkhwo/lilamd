// Builds the LilaMD app icon (1024×1024 PNG with transparency) from art/icon-source.jpeg:
// finds the coloured squircle on the white background, crops it, fits it to the macOS icon grid
// (824×824 body at 100,100) and clips the white corners away.
// Usage: swift scripts/make-icon.swift <source> <out.png>
import AppKit

let args = Array(CommandLine.arguments.dropFirst())
let src = NSImage(contentsOf: URL(fileURLWithPath: args[0]))!
let out = URL(fileURLWithPath: args[1])
var srcRect = CGRect(origin: .zero, size: src.size)
let cg = src.cgImage(forProposedRect: &srcRect, context: nil, hints: nil)!
let w = cg.width, h = cg.height

// Read pixels and take the bounding box of "coloured" pixels (the squircle, not the white or grey shadow).
var px = [UInt8](repeating: 0, count: w * h * 4)
let readCtx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
readCtx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
var minX = w, minY = h, maxX = 0, maxY = 0
for y in 0..<h {
    for x in 0..<w {
        let i = (y * w + x) * 4
        let r = Int(px[i]), b = Int(px[i + 2])
        if r - b > 70 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
    }
}
// Bitmap rows run top-down; CGImage cropping uses the same top-left origin.
let crop = cg.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))!
print("squircle bbox: x \(minX)…\(maxX), y \(minY)…\(maxY)")

let size = 1024
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
// A slightly larger radius than the source corners, so no white survives in the corners.
let squircle = CGPath(roundedRect: body, cornerWidth: 200, cornerHeight: 200, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.28))
ctx.addPath(squircle)
ctx.setFillColor(CGColor(red: 0.85, green: 0.55, blue: 0.15, alpha: 1))
ctx.fillPath()
ctx.restoreGState()

ctx.addPath(squircle)
ctx.clip()
ctx.interpolationQuality = .high
ctx.draw(crop, in: body)

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try rep.representation(using: .png, properties: [:])!.write(to: out)
print(out.path)
