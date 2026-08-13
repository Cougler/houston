// Renders the DMG window background: deep space, a star field, a ringed
// planet, and a dashed transfer-orbit arc carrying the app toward
// /Applications. Output is 1320x840 px tagged 144 DPI, so Finder draws it
// at 660x420 points, crisp on retina.
//
//   swift scripts/dmg-background.swift scripts/dmg-background.png
import AppKit

let size = CGSize(width: 1320, height: 840) // 2x of 660x420
let ctx = CGContext(
    data: nil, width: Int(size.width), height: Int(size.height),
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
ctx.scaleBy(x: 2, y: 2) // draw in points

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

// Space gradient, subtly lighter toward the bottom horizon.
let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [rgb(0x0D0D13), rgb(0x171720)] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: 420), end: CGPoint(x: 0, y: 0),
    options: []
)

// Deterministic star field (seeded LCG, so the art is reproducible).
var seed: UInt64 = 0x48_6F_75_73_74_6F_6E // "Houston"
func rand() -> CGFloat {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return CGFloat((seed >> 33) % 10_000) / 10_000
}
for _ in 0..<110 {
    let x = rand() * 660
    let y = rand() * 420
    let radius = 0.4 + rand() * 1.1
    let alpha = 0.15 + rand() * 0.55
    ctx.setFillColor(rgb(0xE8E8F0, alpha))
    ctx.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
}

// Ringed planet, top right — quiet, out of the icons' way.
let planet = CGPoint(x: 560, y: 340)
ctx.setFillColor(rgb(0xD9C27E, 0.9))
ctx.fillEllipse(in: CGRect(x: planet.x - 16, y: planet.y - 16, width: 32, height: 32))
ctx.saveGState()
ctx.translateBy(x: planet.x, y: planet.y)
ctx.rotate(by: -0.35)
ctx.setStrokeColor(rgb(0xD9C27E, 0.55))
ctx.setLineWidth(2)
ctx.strokeEllipse(in: CGRect(x: -30, y: -9, width: 60, height: 18))
ctx.restoreGState()

// The lunar surface: a vast light moon filling the bottom third. The two
// icons sit on its horizon, and Finder's always-black labels land on
// bright ground where they read clearly. Horizon peaks at y≈185 (CG).
let moonRadius: CGFloat = 1400
let moonCenter = CGPoint(x: 330, y: 185 - moonRadius)
ctx.saveGState()
ctx.addEllipse(in: CGRect(
    x: moonCenter.x - moonRadius, y: moonCenter.y - moonRadius,
    width: moonRadius * 2, height: moonRadius * 2
))
ctx.clip()
let moonGradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [rgb(0xEDEDF2), rgb(0xD2D2DD)] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    moonGradient,
    start: CGPoint(x: 0, y: 185), end: CGPoint(x: 0, y: 0),
    options: []
)
// Craters, kept low so the label line (y ≈ 146-164) stays clean.
let craters: [(x: CGFloat, y: CGFloat, r: CGFloat)] = [
    (120, 62, 20), (250, 28, 13), (420, 48, 24),
    (565, 95, 12), (58, 118, 9), (622, 20, 16), (330, 92, 8),
]
for crater in craters {
    ctx.setFillColor(rgb(0xC4C4D0, 0.5))
    ctx.fillEllipse(in: CGRect(
        x: crater.x - crater.r, y: crater.y - crater.r * 0.6,
        width: crater.r * 2, height: crater.r * 1.2
    ))
    ctx.setStrokeColor(rgb(0xF4F4F8, 0.7))
    ctx.setLineWidth(1.2)
    ctx.strokeEllipse(in: CGRect(
        x: crater.x - crater.r, y: crater.y - crater.r * 0.6,
        width: crater.r * 2, height: crater.r * 1.2
    ))
}
ctx.restoreGState()

// Transfer-orbit arc: dashed, from the app slot to the Applications slot.
// Icons sit at (165, 205) and (495, 205) in Finder's top-left coordinates,
// i.e. y = 215 in CG's bottom-left space; the arc bows above them.
let from = CGPoint(x: 205, y: 235)
let to = CGPoint(x: 448, y: 235)
let control = CGPoint(x: 330, y: 320)
let arc = CGMutablePath()
arc.move(to: from)
arc.addQuadCurve(to: to, control: control)
ctx.setStrokeColor(rgb(0xC79491, 0.75))
ctx.setLineWidth(2.5)
ctx.setLineCap(.round)
ctx.setLineDash(phase: 0, lengths: [1, 9])
ctx.addPath(arc)
ctx.strokePath()

// Arrowhead at the Applications end, following the arc's final tangent.
let tangent = atan2(to.y - control.y, to.x - control.x)
ctx.setLineDash(phase: 0, lengths: [])
ctx.setFillColor(rgb(0xC79491, 0.9))
ctx.saveGState()
ctx.translateBy(x: to.x, y: to.y)
ctx.rotate(by: tangent)
let head = CGMutablePath()
head.move(to: CGPoint(x: 0, y: 0))
head.addLine(to: CGPoint(x: -12, y: 6))
head.addLine(to: CGPoint(x: -12, y: -6))
head.closeSubpath()
ctx.addPath(head)
ctx.fillPath()
ctx.restoreGState()

// Caption between the icons, on the moon — dark text on bright ground.
let caption = NSAttributedString(
    string: "Drag Houston into Applications for liftoff",
    attributes: [
        .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        .foregroundColor: NSColor(calibratedRed: 0.28, green: 0.28, blue: 0.33, alpha: 1),
    ]
)
let line = CTLineCreateWithAttributedString(caption)
let width = CTLineGetTypographicBounds(line, nil, nil, nil)
ctx.textPosition = CGPoint(x: 330 - CGFloat(width) / 2, y: 62)
CTLineDraw(line, ctx)

let image = ctx.makeImage()!
let out = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(out as CFURL, "public.png" as CFString, 1, nil)!
// 144 DPI = Finder treats the 1320px image as 660pt: retina-crisp.
CGImageDestinationAddImage(dest, image, [
    kCGImagePropertyDPIWidth: 144,
    kCGImagePropertyDPIHeight: 144,
] as CFDictionary)
CGImageDestinationFinalize(dest)
print("wrote \(out.path)")
