// Builds the Brain Dump icon from Assets/icon-source.png and writes an .iconset directory.
// Usage: swift make-icon.swift <source.png> <out.iconset>
import AppKit

let args = CommandLine.arguments
guard args.count >= 3, let source = NSImage(contentsOfFile: args[1]),
      let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil)
else { FileHandle.standardError.write(Data("usage: make-icon <source.png> <out.iconset>\n".utf8)); exit(1) }

// Redraw into a known RGBA buffer so pixel scanning is predictable.
let w = cg.width, h = cg.height
var pixels = [UInt8](repeating: 0, count: w * h * 4)
let space = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

// Bounding box of dark pixels = the rounded square (the background is light grey).
var minX = w, minY = h, maxX = -1, maxY = -1
for y in 0..<h {
    for x in 0..<w {
        let i = (y * w + x) * 4
        let lum = (Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])) / 3
        if lum < 90 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
    }
}
guard maxX > minX, maxY > minY else { FileHandle.standardError.write(Data("no icon found\n".utf8)); exit(1) }
let side = min(maxX - minX + 1, maxY - minY + 1)
let cx = (minX + maxX + 1) / 2, cy = (minY + maxY + 1) / 2
// Trim a pixel or two so the anti-aliased grey edge never shows through the mask.
let inset = 2
let crop = CGRect(x: cx - side / 2 + inset, y: cy - side / 2 + inset, width: side - 2 * inset, height: side - 2 * inset)
let cropped = cg.cropping(to: crop)!

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let s = CGFloat(px)
    let size = s * 0.82
    let rect = NSRect(x: (s - size) / 2, y: (s - size) / 2, width: size, height: size)
    NSBezierPath(roundedRect: rect, xRadius: size * 0.225, yRadius: size * 0.225).addClip()
    NSImage(cgImage: cropped, size: NSSize(width: crop.width, height: crop.height)).draw(in: rect)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
