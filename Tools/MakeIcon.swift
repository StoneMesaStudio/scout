import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

// Scout's app icon: the artwork in Assets/AppIcon-source.png, prepared for macOS.
//
//     swift Tools/MakeIcon.swift <output-dir> [lift] [--sheet <path>]
//
// `lift` is how far the dark background is raised, 0 to 1. The artwork came back from the
// illustrator darker than it wanted to be on a Mac's own grey desktop, and lifting the shadows
// rather than the whole image keeps the brass where it was — the background moves, the subject
// does not.
//
// The rest is Apple's geometry: the art is a squircle covering 824 of a 1024 canvas, with a soft
// shadow under it. Drawing the full square instead is the most common way a Mac icon ends up
// looking subtly wrong next to every other one in the Dock.

let outDir = CommandLine.arguments[1]
let lift = CommandLine.arguments.count > 2 ? (Double(CommandLine.arguments[2]) ?? 0.5) : 0.5
let sheetPath = CommandLine.arguments.firstIndex(of: "--sheet").map { CommandLine.arguments[$0 + 1] }

let sourceURL = URL(filePath: FileManager.default.currentDirectoryPath)
    .appending(path: "Assets/AppIcon-source.png")
guard let source = CIImage(contentsOf: sourceURL) else {
    print("No artwork at \(sourceURL.path)"); exit(1)
}

let inset: CGFloat = 100.0 / 1024.0
let cornerFraction: CGFloat = 0.2237
let context = CIContext()

/// Raise the dark end of the range and leave the highlights alone.
func lifted(_ image: CIImage, by amount: Double) -> CIImage {
    guard amount > 0 else { return image }
    let a = CGFloat(min(max(amount, 0), 1))
    let curve = CIFilter.toneCurve()
    curve.inputImage = image
    curve.point0 = CGPoint(x: 0.00, y: 0.00 + 0.17 * a)
    curve.point1 = CGPoint(x: 0.25, y: 0.25 + 0.14 * a)
    curve.point2 = CGPoint(x: 0.50, y: 0.50 + 0.08 * a)
    curve.point3 = CGPoint(x: 0.75, y: 0.75 + 0.03 * a)
    curve.point4 = CGPoint(x: 1.00, y: 1.00)
    return curve.outputImage ?? image
}

func nsImage(from ci: CIImage) -> NSImage? {
    guard let cg = context.createCGImage(ci, from: ci.extent) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: ci.extent.width, height: ci.extent.height))
}

/// One icon, at one size, with one amount of lift.
func render(side: CGFloat, lift amount: Double) -> Data? {
    guard let art = nsImage(from: lifted(source, by: amount)) else { return nil }
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gc
    gc.imageInterpolation = .high
    let ctx = gc.cgContext

    let pad = side * inset
    let body = CGRect(x: pad, y: pad, width: side - pad * 2, height: side - pad * 2)
    let shape = NSBezierPath(roundedRect: body,
                             xRadius: body.width * cornerFraction,
                             yRadius: body.width * cornerFraction)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -side * 0.012),
                  blur: side * 0.03,
                  color: NSColor(white: 0, alpha: 0.28).cgColor)
    ctx.addPath(shape.cgPath)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape.cgPath)
    ctx.clip()
    art.draw(in: body, from: .zero, operation: .copy, fraction: 1)
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

// A sheet of three strengths, for choosing between them rather than guessing.
if let sheetPath {
    for (name, amount) in [("subtle", 0.28), ("medium", 0.5), ("strong", 0.75)] {
        for side in [256, 128, 64, 32] as [CGFloat] {
            if let png = render(side: side, lift: amount) {
                try? png.write(to: URL(filePath: "\(sheetPath)/\(name)-\(Int(side)).png"))
            }
        }
    }
    print("wrote the comparison sheet to \(sheetPath)")
    exit(0)
}

// `icon_16x16@2x` and `icon_32x32` are the same 32 pixels and both files must exist — the asset
// catalogue will not compile with one missing.
let wanted: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for (name, side) in wanted {
    guard let png = render(side: side, lift: lift) else { print("could not render \(name)"); exit(1) }
    try? png.write(to: URL(filePath: "\(outDir)/\(name).png"))
}

let contents = "{\n  \"images\" : [\n" + wanted.map { name, side in
    let scale = name.hasSuffix("@2x") ? 2 : 1
    let points = Int(side) / scale
    return """
        {
          "filename" : "\(name).png",
          "idiom" : "mac",
          "scale" : "\(scale)x",
          "size" : "\(points)x\(points)"
        }
    """
}.joined(separator: ",\n") + "\n  ],\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n}\n"
try? contents.write(to: URL(filePath: "\(outDir)/Contents.json"), atomically: true, encoding: .utf8)
print("wrote \(wanted.count) sizes, shadows lifted \(Int(lift * 100))%")
