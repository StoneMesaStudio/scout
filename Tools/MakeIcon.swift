import AppKit

// Scout's app icon, drawn rather than exported.
//
// Kept as code so every size regenerates from one source and a tweak is a diff rather than a new
// binary nobody can edit. `bin/make-icon.sh` runs this and writes the asset catalogue.
//
//     swift Tools/MakeIcon.swift <output-dir> [variant]

let outDir = CommandLine.arguments[1]
let chosen = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "1-slate"

// Apple's convention since Big Sur: the artwork is a squircle covering 824 of a 1024 canvas,
// with a soft shadow underneath. Everything below is expressed as a fraction of the canvas so
// one routine renders every size.
let inset: CGFloat = 100.0 / 1024.0
let cornerFraction: CGFloat = 0.2237

func squircle(in rect: CGRect) -> NSBezierPath {
    NSBezierPath(roundedRect: rect,
                 xRadius: rect.width * cornerFraction,
                 yRadius: rect.width * cornerFraction)
}

func render(_ side: CGFloat, _ draw: (CGContext, CGRect) -> Void) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gc
    let ctx = gc.cgContext

    let pad = side * inset
    let body = CGRect(x: pad, y: pad, width: side - pad * 2, height: side - pad * 2)

    // The shadow the OS expects under a macOS icon.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -side * 0.012),
                  blur: side * 0.03,
                  color: NSColor(white: 0, alpha: 0.28).cgColor)
    ctx.addPath(squircle(in: body).cgPath)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle(in: body).cgPath)
    ctx.clip()
    draw(ctx, body)
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

func gradient(_ ctx: CGContext, _ r: CGRect, _ top: NSColor, _ bottom: NSColor) {
    let colors = [top.cgColor, bottom.cgColor] as CFArray
    guard let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                             colors: colors, locations: [0, 1]) else { return }
    ctx.drawLinearGradient(g, start: CGPoint(x: r.midX, y: r.maxY),
                           end: CGPoint(x: r.midX, y: r.minY), options: [])
}

/// The lens: a ring plus a handle, drawn as strokes so it stays crisp when scaled down.
func magnifier(_ ctx: CGContext, _ r: CGRect, colour: NSColor, weight: CGFloat, lensFill: (CGContext, CGRect) -> Void) {
    let unit = r.width
    let lensRadius = unit * 0.235
    let centre = CGPoint(x: r.midX - unit * 0.055, y: r.midY + unit * 0.065)
    let lens = CGRect(x: centre.x - lensRadius, y: centre.y - lensRadius,
                      width: lensRadius * 2, height: lensRadius * 2)

    ctx.saveGState()
    ctx.addEllipse(in: lens)
    ctx.clip()
    lensFill(ctx, lens)
    ctx.restoreGState()

    ctx.setStrokeColor(colour.cgColor)
    ctx.setLineWidth(unit * weight)
    ctx.setLineCap(.round)
    ctx.strokeEllipse(in: lens)

    // Handle, on the 45° the eye expects.
    let a = CGPoint(x: centre.x + lensRadius * 0.74, y: centre.y - lensRadius * 0.74)
    let b = CGPoint(x: centre.x + unit * 0.285, y: centre.y - unit * 0.285)
    ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
}

/// The eight source colours, in the app's own order.
let lanes: [NSColor] = [
    .systemBlue, .systemOrange, .systemIndigo, .systemGreen,
    .systemPurple, .systemGray, .systemYellow, .systemRed,
]

// ---- 1. Dark slate, white lens, colour bars inside it -----------------------
func variantBars(_ ctx: CGContext, _ r: CGRect) {
    gradient(ctx, r, NSColor(srgbRed: 0.29, green: 0.35, blue: 0.46, alpha: 1),
                     NSColor(srgbRed: 0.13, green: 0.16, blue: 0.23, alpha: 1))
    magnifier(ctx, r, colour: .white, weight: 0.052) { c, lens in
        let rows = 4
        let gap = lens.height / CGFloat(rows)
        for i in 0..<rows {
            let bar = CGRect(x: lens.minX, y: lens.maxY - gap * CGFloat(i + 1),
                             width: lens.width, height: gap * 0.56)
            c.setFillColor(lanes[i * 2].withAlphaComponent(0.95).cgColor)
            c.fill(bar)
        }
    }
}

// ---- 2. Light, dark lens, colour bars ---------------------------------------
func variantLight(_ ctx: CGContext, _ r: CGRect) {
    gradient(ctx, r, NSColor(srgbRed: 0.98, green: 0.985, blue: 0.99, alpha: 1),
                     NSColor(srgbRed: 0.86, green: 0.88, blue: 0.92, alpha: 1))
    magnifier(ctx, r, colour: NSColor(srgbRed: 0.15, green: 0.18, blue: 0.24, alpha: 1),
              weight: 0.052) { c, lens in
        let rows = 4
        let gap = lens.height / CGFloat(rows)
        for i in 0..<rows {
            let bar = CGRect(x: lens.minX, y: lens.maxY - gap * CGFloat(i + 1),
                             width: lens.width, height: gap * 0.56)
            c.setFillColor(lanes[i * 2].cgColor)
            c.fill(bar)
        }
    }
}

// ---- 3. Blue, white lens, a fan of source colours behind it -----------------
func variantFan(_ ctx: CGContext, _ r: CGRect) {
    gradient(ctx, r, NSColor(srgbRed: 0.24, green: 0.51, blue: 0.98, alpha: 1),
                     NSColor(srgbRed: 0.07, green: 0.26, blue: 0.72, alpha: 1))

    // A quarter-turn fan of the eight source colours, low contrast, behind the lens.
    let unit = r.width
    let centre = CGPoint(x: r.minX + unit * 0.10, y: r.minY + unit * 0.10)
    ctx.saveGState()
    for (i, colour) in lanes.enumerated() {
        let start = CGFloat(i) * (.pi / 2 / CGFloat(lanes.count))
        let end = CGFloat(i + 1) * (.pi / 2 / CGFloat(lanes.count))
        ctx.move(to: centre)
        ctx.addArc(center: centre, radius: unit * 1.15, startAngle: start, endAngle: end, clockwise: false)
        ctx.closePath()
        ctx.setFillColor(colour.withAlphaComponent(0.30).cgColor)
        ctx.fillPath()
    }
    ctx.restoreGState()

    magnifier(ctx, r, colour: .white, weight: 0.058) { c, lens in
        c.setFillColor(NSColor(white: 1, alpha: 0.22).cgColor)
        c.fill(lens)
    }
}

let variants: [String: (CGContext, CGRect) -> Void] = [
    "1-slate": variantBars,
    "2-light": variantLight,
    "3-blue": variantFan,
]

guard let draw = variants[chosen] else {
    print("Unknown variant \(chosen). Choose one of: \(variants.keys.sorted().joined(separator: ", "))")
    exit(2)
}

// Every size macOS asks for, at both scales. `icon_16x16@2x` and `icon_32x32` are the same 32
// pixels and both files must exist — the asset catalogue will not compile with one missing.
let wanted: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for (name, side) in wanted {
    guard let png = render(side, draw) else {
        print("could not render \(name)")
        exit(1)
    }
    try? png.write(to: URL(filePath: "\(outDir)/\(name).png"))
}

let contents = """
{
  "images" : [
""" + wanted.map { name, side in
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
}.joined(separator: ",") + """
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""
try? contents.write(to: URL(filePath: "\(outDir)/Contents.json"), atomically: true, encoding: .utf8)
print("wrote \(wanted.count) sizes of \(chosen) to \(outDir)")
