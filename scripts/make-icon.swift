// Renders the app icon: swift scripts/make-icon.swift <out.png> [dark]
import AppKit

let size = 1024
let out = CommandLine.arguments[1]
let dark = CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "dark"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let gc = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = gc
let ctx = gc.cgContext
let S = CGFloat(size)

let colors = (dark
    ? [NSColor(srgbRed: 0.10, green: 0.14, blue: 0.11, alpha: 1).cgColor, NSColor(srgbRed: 0.02, green: 0.04, blue: 0.03, alpha: 1).cgColor]
    : [NSColor(srgbRed: 0.22, green: 0.88, blue: 0.45, alpha: 1).cgColor, NSColor(srgbRed: 0.01, green: 0.52, blue: 0.29, alpha: 1).cgColor]) as CFArray
let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: S), end: CGPoint(x: S, y: 0), options: [])

let config = NSImage.SymbolConfiguration(pointSize: 500, weight: .bold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [dark ? NSColor(srgbRed: 0.25, green: 0.86, blue: 0.45, alpha: 1) : .white]))
let symbol = NSImage(systemSymbolName: "dumbbell.fill", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
let s = symbol.size
ctx.saveGState()
ctx.translateBy(x: S / 2, y: S / 2)
ctx.rotate(by: .pi / 4)
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: NSColor.black.withAlphaComponent(0.25).cgColor)
symbol.draw(in: NSRect(x: -s.width / 2, y: -s.height / 2, width: s.width, height: s.height))
ctx.restoreGState()
NSGraphicsContext.restoreGraphicsState()

// Flatten to opaque RGB (App Store icons can't have alpha).
let cg = rep.cgImage!
let flat = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                     space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
flat.draw(cg, in: CGRect(x: 0, y: 0, width: S, height: S))
let final = NSBitmapImageRep(cgImage: flat.makeImage()!)
try! final.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("ok")
