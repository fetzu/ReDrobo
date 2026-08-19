// ReDrobo's app icon, drawn rather than stored.
//
// The Drobo wordmark is someone else's trademark, so what carries over from the
// original is the form language: a black moulded enclosure face and the row of
// drive bays, here lying flat with their status LEDs upright at the left. The
// green arc is the "Re" — an again-mark whose arrow lands at twelve o'clock.
//
// Run via `make icon` in ReDrobo/. Output is ReDrobo.icns plus the iconset.

import AppKit
import CoreGraphics

let S: CGFloat = 1024

let bodyTop    = NSColor(calibratedWhite: 0.24, alpha: 1)
let bodyBottom = NSColor(calibratedWhite: 0.06, alpha: 1)
let bayFill    = NSColor(calibratedWhite: 0.32, alpha: 1)
let bayEdge    = NSColor(calibratedWhite: 0.46, alpha: 1)
let green      = NSColor(calibratedRed: 0.30, green: 0.85, blue: 0.42, alpha: 1)

/// Everything adjustable, as fractions of the canvas.
///
/// macOS 26 and 27 draw their stock icons with a big central glyph that fills
/// most of the square, so the drive stack is sized to match that rather than
/// sitting politely inside the arc.
struct Geometry {
    var arcRadius: CGFloat
    var arcWidth: CGFloat
    var stackWidth: CGFloat
    var stackHeight: CGFloat
    /// When the stack is wider than the arc, the arc is clipped away around it
    /// so it reads as passing behind rather than colliding. This is the margin
    /// of that gap.
    var gap: CGFloat = 0.022
    var clipArcBehindStack: Bool = false
    /// Behind the stack on the left, in front of it on the right, so the arc
    /// threads through rather than being interrupted by it.
    var weaveThroughStack: Bool = false
    var gapRatio: CGFloat = 0.02      // between the disks; almost touching
}

/// Big ring near the edge with the stack inscribed inside it. Nothing overlaps,
/// so the arc stays a complete circle. The stack's corners are the constraint:
/// they have to clear the arc's inner edge, which is what sets the size.
let inscribed = Geometry(arcRadius: 0.385, arcWidth: 0.075,
                         stackWidth: 0.52, stackHeight: 0.40)

/// The stack is wider than the arc's diameter, so the arc passes behind it and
/// shows as an arrow above and a cap below.
///
/// The gap has to be wide enough to swallow the arc's *outer* edge where the
/// two cross, or a sliver of it survives at the stack's ends and reads as a
/// rendering fault. That means stackWidth/2 + gap > arcRadius + arcWidth/2.
let overlapping = Geometry(arcRadius: 0.315, arcWidth: 0.080,
                           stackWidth: 0.66, stackHeight: 0.44,
                           gap: 0.032, clipArcBehindStack: true)

/// The same proportions, but the arc threads through the stack instead of
/// stopping at it: behind on the left, in front on the right. Far more of the
/// circle survives, which is the point.
let woven = Geometry(arcRadius: 0.335, arcWidth: 0.082,
                     stackWidth: 0.64, stackHeight: 0.40,
                     gap: 0.026, weaveThroughStack: true)

/// The stack dominates and the arc is reduced to an accent.
let dominant = Geometry(arcRadius: 0.300, arcWidth: 0.085,
                        stackWidth: 0.70, stackHeight: 0.50,
                        gap: 0.036, clipArcBehindStack: true)

let chosen = woven

func squircle(_ r: CGRect) -> NSBezierPath {
    NSBezierPath(roundedRect: r, xRadius: r.width * 0.2237, yRadius: r.width * 0.2237)
}

func drawBody(_ ctx: CGContext, inset: CGFloat = 0.06) {
    let r = CGRect(x: S * inset, y: S * inset,
                   width: S * (1 - 2 * inset), height: S * (1 - 2 * inset))
    ctx.saveGState()
    squircle(r).setClip()
    NSGradient(colors: [bodyTop, bodyBottom])!.draw(in: r, angle: -90)
    ctx.setBlendMode(.plusLighter)
    NSGradient(colors: [NSColor(calibratedWhite: 1, alpha: 0.10),
                        NSColor(calibratedWhite: 1, alpha: 0)])!
        .draw(in: CGRect(x: r.minX, y: r.midY, width: r.width, height: r.height / 2), angle: -90)
    ctx.restoreGState()

    ctx.saveGState()
    NSColor(calibratedWhite: 1, alpha: 0.14).setStroke()
    let s = squircle(r.insetBy(dx: 1.5, dy: 1.5)); s.lineWidth = 3; s.stroke()
    ctx.restoreGState()
}

func drawBays(_ ctx: CGContext, rect: CGRect, count: Int = 5, gapRatio: CGFloat) {
    let gap = rect.height * gapRatio
    let h = (rect.height - gap * CGFloat(count - 1)) / CGFloat(count)
    for i in 0..<count {
        let y = rect.maxY - h - CGFloat(i) * (h + gap)
        let bay = CGRect(x: rect.minX, y: y, width: rect.width, height: h)
        let p = NSBezierPath(roundedRect: bay, xRadius: h * 0.32, yRadius: h * 0.32)
        bayFill.setFill(); p.fill()
        bayEdge.setStroke(); p.lineWidth = max(1, S * 0.0035); p.stroke()

        let w = h * 0.26, tall = h * 0.56
        let led = CGRect(x: bay.minX + h * 0.36, y: bay.midY - tall / 2,
                         width: w, height: tall)
        let lp = NSBezierPath(roundedRect: led, xRadius: w / 2, yRadius: w / 2)
        green.setFill(); lp.fill()
        ctx.saveGState()
        ctx.setBlendMode(.plusLighter)
        green.withAlphaComponent(0.30).setFill()
        NSBezierPath(roundedRect: led.insetBy(dx: -w * 0.7, dy: -w * 0.7),
                     xRadius: w, yRadius: w).fill()
        ctx.restoreGState()
    }
}

/// Angles are the usual maths convention, so the arrow lands at 90: noon.
///
/// The arc runs 170 -> 450, which is upper-left, down the left side, along the
/// bottom, up the right and back to the top. Splitting it at 270 — the bottom,
/// where the stack is nowhere near — gives two halves that can be drawn either
/// side of the stack without a visible join: the left half behind it, the right
/// half in front, so the ribbon reads as passing through.
let arcStart: CGFloat = 170
let arcEnd: CGFloat = 450
let arcSplit: CGFloat = 270

func arcSegment(_ ctx: CGContext, center: CGPoint, radius: CGFloat, width: CGFloat,
                from: CGFloat, to: CGFloat, colour: NSColor = green,
                arrowhead: Bool = false) {
    let path = NSBezierPath()
    path.appendArc(withCenter: center, radius: radius, startAngle: from, endAngle: to)
    colour.setStroke(); path.lineWidth = width; path.lineCapStyle = .round; path.stroke()
    guard arrowhead else { return }

    let a = to * .pi / 180
    let base = CGPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius)
    let tangent = CGPoint(x: -sin(a), y: cos(a))
    let radial  = CGPoint(x:  cos(a), y: sin(a))
    let half = width * 1.15, len = width * 2.1
    let head = NSBezierPath()
    head.move(to: CGPoint(x: base.x + tangent.x * len, y: base.y + tangent.y * len))
    head.line(to: CGPoint(x: base.x + radial.x * half, y: base.y + radial.y * half))
    head.line(to: CGPoint(x: base.x - radial.x * half, y: base.y - radial.y * half))
    head.close()
    colour.setFill(); head.fill()
}

func draw(_ ctx: CGContext, _ g: Geometry = chosen) {
    drawBody(ctx)
    let c = CGPoint(x: S / 2, y: S / 2)

    // Nudged a hair left: the arrowhead's mass sits top-left, so a
    // mathematically centred stack reads as shifted right.
    let w = S * g.stackWidth, h = S * g.stackHeight
    let stack = CGRect(x: c.x - w / 2 - S * 0.004, y: c.y - h / 2, width: w, height: h)

    let r = S * g.arcRadius, aw = S * g.arcWidth
    let hole = stack.insetBy(dx: -S * g.gap, dy: -S * g.gap)
    let holeRadius = hole.height * 0.16

    func clipOutsideStack(_ body: () -> Void) {
        ctx.saveGState()
        let clip = NSBezierPath(rect: CGRect(x: 0, y: 0, width: S, height: S))
        clip.append(NSBezierPath(roundedRect: hole,
                                 xRadius: holeRadius, yRadius: holeRadius))
        clip.windingRule = .evenOdd
        clip.addClip()
        body()
        ctx.restoreGState()
    }

    guard g.weaveThroughStack else {
        if g.clipArcBehindStack {
            clipOutsideStack {
                arcSegment(ctx, center: c, radius: r, width: aw,
                           from: arcStart, to: arcEnd, arrowhead: true)
            }
        } else {
            arcSegment(ctx, center: c, radius: r, width: aw,
                       from: arcStart, to: arcEnd, arrowhead: true)
        }
        drawBays(ctx, rect: stack, gapRatio: g.gapRatio)
        return
    }

    // Left half, behind: clipped so the stack punches it out.
    clipOutsideStack {
        arcSegment(ctx, center: c, radius: r, width: aw, from: arcStart, to: arcSplit)
    }

    drawBays(ctx, rect: stack, gapRatio: g.gapRatio)

    // Right half, in front. A narrow translucent under-stroke, drawn only where
    // it crosses the stack, separates the green from the disks it passes over so
    // the crossing reads as depth. It has to be thin and see-through: an opaque
    // band as wide as the gap reads as a black stripe painted across the disks,
    // not as a shadow.
    ctx.saveGState()
    NSBezierPath(roundedRect: hole, xRadius: holeRadius, yRadius: holeRadius).addClip()
    arcSegment(ctx, center: c, radius: r, width: aw + S * 0.016,
               from: arcSplit, to: arcEnd,
               colour: NSColor(calibratedWhite: 0, alpha: 0.55))
    ctx.restoreGState()

    arcSegment(ctx, center: c, radius: r, width: aw,
               from: arcSplit, to: arcEnd, arrowhead: true)
}

func render(size: CGFloat, _ g: Geometry = chosen) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocusFlipped(false)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: size / S, y: size / S)
    draw(ctx, g)
    img.unlockFocus()
    return img
}

func writePNG(_ img: NSImage, _ path: String) {
    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
}

if CommandLine.arguments.contains("--variants") {
    let variants: [(String, Geometry)] = [
        ("1 overlapping (shipped)", overlapping),
        ("2 woven", woven),
        ("3 inscribed", inscribed),
    ]
    let big: CGFloat = 300, pad: CGFloat = 28
    let sheetW = pad + (big + pad) * CGFloat(variants.count)
    let sheetH = pad * 2 + big + 150
    let sheet = NSImage(size: NSSize(width: sheetW, height: sheetH))
    sheet.lockFocusFlipped(false)
    NSColor(calibratedWhite: 0.13, alpha: 1).setFill()
    NSBezierPath(rect: CGRect(x: 0, y: 0, width: sheetW, height: sheetH)).fill()
    for (i, (name, g)) in variants.enumerated() {
        let x = pad + (big + pad) * CGFloat(i)
        let y = sheetH - pad - big
        render(size: big, g).draw(in: CGRect(x: x, y: y, width: big, height: big))
        var sx = x
        for size in [96, 64, 32, 16] {
            let s = CGFloat(size)
            render(size: s, g).draw(in: CGRect(x: sx, y: y - 22 - s, width: s, height: s))
            sx += s + 14
        }
        (name as NSString).draw(at: CGPoint(x: x, y: pad),
            withAttributes: [.font: NSFont.systemFont(ofSize: 17, weight: .medium),
                             .foregroundColor: NSColor.white])
    }
    sheet.unlockFocus()
    writePNG(sheet, (CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
                    + "/icon-variants.png")
    print("wrote the comparison sheet")
    exit(0)
}

// iconutil wants exactly these names.
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "ReDrobo.iconset"
try? FileManager.default.createDirectory(atPath: out,
                                         withIntermediateDirectories: true)
let wanted: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]
for (size, name) in wanted {
    writePNG(render(size: CGFloat(size)), "\(out)/\(name).png")
}
print("wrote \(wanted.count) sizes to \(out)")
