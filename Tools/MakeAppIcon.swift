import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Renders every SwitchBlade app icon, plus the previews the settings picker
// shows, straight into the asset catalogue:
//
//     swift Tools/MakeAppIcon.swift SwitchBlade/Assets.xcassets
//
// The mark is a folding knife flicked open far enough that the handle and the
// blade form a checkmark. It carries the name, and a checkmark is the app's
// one destructive-feeling action: mark it watched and it leaves the shelf.
//
// The icons are kept as code rather than flat exports so the palettes can
// follow Design/Theme.swift, and so a new style costs one entry in `iconSets`
// rather than a round trip through a drawing tool.
//
// Geometry is written in an arbitrary "design space" and fitted to the canvas
// at draw time, so changing a length can never push artwork off the edge.

typealias RGB = (CGFloat, CGFloat, CGFloat)

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func cg(_ c: RGB, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [c.0, c.1, c.2, a])!
}

// MARK: - Geometry

let pivot = CGPoint(x: 352, y: 706)

let handleAngle: CGFloat = 152      // degrees above horizontal, pointing up-left
let handleLength: CGFloat = 300
let handleHalfWidth: CGFloat = 52

let bladeAngle: CGFloat = 45        // up-right, the long arm of the check
let bladeLength: CGFloat = 540
let bladeHalfWidth: CGFloat = 62

let rivetRadius: CGFloat = 26

/// Rotates a path built along +x into place around the pivot. y grows downward
/// in design space, so a negative rotation swings the arm upward.
func placed(_ path: CGPath, angle: CGFloat) -> CGPath {
    var t = CGAffineTransform(translationX: pivot.x, y: pivot.y)
        .rotated(by: -angle * .pi / 180)
    return path.copy(using: &t)!
}

/// Closes an arm with a semicircle centred exactly on the pivot, so neither
/// shape spurs out past the joint. The blade's cap is the wider of the two and
/// is drawn last, which is what makes it read as swinging out of the handle.
private func capAtPivot(_ p: CGMutablePath, radius: CGFloat) {
    p.addArc(center: .zero, radius: radius,
             startAngle: .pi / 2, endAngle: 3 * .pi / 2, clockwise: false)
    p.closeSubpath()
}

/// The handle: an even bar with a rounded butt.
func handlePath() -> CGPath {
    let l = handleLength, w = handleHalfWidth
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 0, y: -w))
    p.addLine(to: CGPoint(x: l * 0.84, y: -w * 0.94))
    p.addCurve(to: CGPoint(x: l, y: 0),
               control1: CGPoint(x: l * 0.97, y: -w * 0.90),
               control2: CGPoint(x: l, y: -w * 0.52))
    p.addCurve(to: CGPoint(x: l * 0.84, y: w * 0.94),
               control1: CGPoint(x: l, y: w * 0.52),
               control2: CGPoint(x: l * 0.97, y: w * 0.90))
    p.addLine(to: CGPoint(x: 0, y: w))
    capAtPivot(p, radius: w)
    return placed(p, angle: handleAngle)
}

/// The blade: a clip point — the spine runs straight then dips to the tip,
/// while the cutting edge bellies out below it.
func bladePath() -> CGPath {
    let l = bladeLength, w = bladeHalfWidth
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 0, y: -w))
    p.addCurve(to: CGPoint(x: l, y: 0),
               control1: CGPoint(x: l * 0.58, y: -w * 0.98),
               control2: CGPoint(x: l * 0.90, y: -w * 0.32))
    p.addCurve(to: CGPoint(x: 0, y: w),
               control1: CGPoint(x: l * 0.68, y: w * 0.58),
               control2: CGPoint(x: l * 0.28, y: w * 1.00))
    capAtPivot(p, radius: w)
    return placed(p, angle: bladeAngle)
}

func endpoint(angle: CGFloat, length: CGFloat) -> CGPoint {
    let r = -angle * .pi / 180
    return CGPoint(x: pivot.x + length * cos(r), y: pivot.y + length * sin(r))
}

// MARK: - Palettes

struct Palette {
    /// nil means a transparent background. Only the adaptive icon's dark and
    /// tinted variants want that — iOS composites those over its own backdrop.
    /// A pinned alternate icon has to paint its own.
    var background: (RGB, RGB)?
    var handle: (RGB, RGB)      // base → butt
    var blade: (RGB, RGB)       // base → tip
    var rivet: RGB
    /// Blur radius, in design-space units, for the glow behind each shape.
    var glow: CGFloat?
}

// The two brand colours, taken from Color.appAccent / .appAccentAlt in
// Design/Theme.swift, so the icon and the app's chrome match.
let lightPalette = Palette(
    background: ((0.988, 0.990, 0.998), (0.855, 0.871, 0.937)),
    handle: ((0.129, 0.451, 0.443), (0.094, 0.345, 0.337)),
    blade: ((0.216, 0.294, 0.671), (0.365, 0.451, 0.827)),
    rivet: (0.976, 0.980, 0.992),
    glow: nil
)

let darkPalette = Palette(
    background: nil,
    handle: ((0.502, 0.741, 0.729), (0.365, 0.596, 0.584)),
    blade: ((0.478, 0.553, 0.847), (0.667, 0.729, 0.969)),
    rivet: (0.055, 0.063, 0.086),
    glow: nil
)

// Tinted variants are re-coloured from luminance, so this one is drawn in greys.
let tintedPalette = Palette(
    background: nil,
    handle: ((0.596, 0.596, 0.596), (0.478, 0.478, 0.478)),
    blade: ((0.847, 0.847, 0.847), (1.0, 1.0, 1.0)),
    rivet: (0.180, 0.180, 0.180),
    glow: nil
)

/// The backdrop iOS itself puts behind a dark icon. A pinned Dark icon has to
/// paint it, and the previews need it too or a transparent icon would render
/// as a hole in the settings list.
let systemDarkBackground: (RGB, RGB) = ((0.129, 0.141, 0.161), (0.020, 0.024, 0.031))

var pinnedDarkPalette: Palette {
    var palette = darkPalette
    palette.background = systemDarkBackground
    return palette
}

let neonPalette = Palette(
    background: ((0.043, 0.035, 0.078), (0.008, 0.008, 0.020)),
    handle: ((0.133, 0.925, 0.847), (0.055, 0.635, 0.729)),
    blade: ((1.0, 0.239, 0.588), (0.667, 0.353, 0.980)),
    rivet: (1.0, 1.0, 1.0),
    glow: 46
)

// MARK: - Icon sets

/// One asset-catalogue `.appiconset`. The adaptive icon is the only one with
/// appearance variants; the rest are deliberately pinned, which is the whole
/// point of choosing them.
struct IconSet {
    let assetName: String
    let base: Palette
    var dark: Palette?
    var tinted: Palette?
    /// Palette the settings preview should show, when it differs from `base`.
    var previewOverride: Palette?
}

let iconSets = [
    IconSet(assetName: "AppIcon", base: lightPalette,
            dark: darkPalette, tinted: tintedPalette),
    IconSet(assetName: "AppIconLight", base: lightPalette),
    IconSet(assetName: "AppIconDark", base: pinnedDarkPalette),
    IconSet(assetName: "AppIconNeon", base: neonPalette)
]

// MARK: - Drawing

func fillGradient(_ ctx: CGContext, path: CGPath, from: CGPoint, to: CGPoint, _ pair: (RGB, RGB)) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let gradient = CGGradient(
        colorsSpace: space,
        colors: [cg(pair.0), cg(pair.1)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        gradient, start: from, end: to,
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    ctx.restoreGState()
}

/// Lays a glow under a shape. A gradient fill casts no shadow, so the shape is
/// first filled flat purely to throw one, then covered by the gradient.
func drawGlow(_ ctx: CGContext, path: CGPath, colour: RGB, blur: CGFloat) {
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: blur, color: cg(colour, 0.85))
    ctx.addPath(path)
    ctx.setFillColor(cg(colour))
    ctx.fillPath()
    ctx.restoreGState()
}

func render(_ palette: Palette, size: CGFloat) -> CGImage {
    // A transparent icon needs an alpha channel; an opaque one must not have
    // one, or the App Store rejects the upload.
    let transparent = palette.background == nil
    let ctx = CGContext(
        data: nil,
        width: Int(size), height: Int(size),
        bitsPerComponent: 8, bytesPerRow: 0,
        space: space,
        bitmapInfo: transparent
            ? CGImageAlphaInfo.premultipliedLast.rawValue
            : CGImageAlphaInfo.noneSkipLast.rawValue
    )!

    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)

    // Flip to a y-down design space, matching how the geometry above reads.
    ctx.translateBy(x: 0, y: size)
    ctx.scaleBy(x: 1, y: -1)

    if let bg = palette.background {
        let gradient = CGGradient(
            colorsSpace: space,
            colors: [cg(bg.0), cg(bg.1)] as CFArray,
            locations: [0, 1]
        )!
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: size, y: size),
            options: []
        )
    }

    let handle = handlePath()
    let blade = bladePath()
    let bounds = handle.boundingBoxOfPath.union(blade.boundingBoxOfPath)

    // Apple's icon grid keeps artwork inside roughly 80% of the canvas. The
    // check is wider than it is tall, so the width is what binds.
    let target = size * 0.82
    let scale = min(target / bounds.width, target / bounds.height)
    ctx.translateBy(x: size / 2, y: size / 2)
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: -bounds.midX, y: -bounds.midY)

    if let blur = palette.glow {
        drawGlow(ctx, path: handle, colour: palette.handle.0, blur: blur)
        drawGlow(ctx, path: blade, colour: palette.blade.0, blur: blur)
    }

    fillGradient(ctx, path: handle,
                 from: pivot, to: endpoint(angle: handleAngle, length: handleLength),
                 palette.handle)
    fillGradient(ctx, path: blade,
                 from: pivot, to: endpoint(angle: bladeAngle, length: bladeLength),
                 palette.blade)

    ctx.setFillColor(cg(palette.rivet))
    ctx.fillEllipse(in: CGRect(x: pivot.x - rivetRadius, y: pivot.y - rivetRadius,
                               width: rivetRadius * 2, height: rivetRadius * 2))

    return ctx.makeImage()!
}

// MARK: - Asset catalogue

func write(_ image: CGImage, to path: String) {
    let dest = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil
    )!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        FileHandle.standardError.write(Data("failed writing \(path)\n".utf8))
        exit(1)
    }
}

func write(contents: String, to path: String) {
    try! Data(contents.utf8).write(to: URL(fileURLWithPath: path))
}

func makeDirectory(_ path: String) {
    try! FileManager.default.createDirectory(
        atPath: path, withIntermediateDirectories: true
    )
}

func manifest(images: [[String: Any]]) -> String {
    let root: [String: Any] = [
        "images": images,
        "info": ["author": "xcode", "version": 1]
    ]
    let data = try! JSONSerialization.data(
        withJSONObject: root, options: [.prettyPrinted, .sortedKeys]
    )
    return String(decoding: data, as: UTF8.self) + "\n"
}

func luminosity(_ value: String) -> [[String: String]] {
    [["appearance": "luminosity", "value": value]]
}

/// One 1024pt entry per appearance. Everything else about an iOS app icon —
/// the 20pt through 60pt renderings — is derived by the asset compiler.
func appIconContents(_ set: IconSet) -> String {
    func entry(_ suffix: String?, appearance: String?) -> [String: Any] {
        var image: [String: Any] = [
            "filename": "\(set.assetName)\(suffix.map { "-\($0)" } ?? "").png",
            "idiom": "universal",
            "platform": "ios",
            "size": "1024x1024"
        ]
        if let appearance { image["appearances"] = luminosity(appearance) }
        return image
    }

    var images = [entry(nil, appearance: nil)]
    if set.dark != nil { images.append(entry("Dark", appearance: "dark")) }
    if set.tinted != nil { images.append(entry("Tinted", appearance: "tinted")) }
    return manifest(images: images)
}

/// A single-scale image: rendered at exactly the pixel size the picker draws
/// it at on a 3x screen, so it needs no resampling.
func previewContents(_ name: String, hasDark: Bool) -> String {
    var images: [[String: Any]] = [["filename": "\(name).png", "idiom": "universal"]]
    if hasDark {
        images.append([
            "filename": "\(name)-Dark.png",
            "idiom": "universal",
            "appearances": luminosity("dark")
        ])
    }
    return manifest(images: images)
}

// MARK: - Main

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: MakeAppIcon <path to .xcassets>\n".utf8))
    exit(1)
}
let catalogue = arguments[1]

/// 60pt at 3x — the size the settings picker draws a preview at.
let previewSize: CGFloat = 180

for set in iconSets {
    let directory = "\(catalogue)/\(set.assetName).appiconset"
    makeDirectory(directory)

    write(render(set.base, size: 1024), to: "\(directory)/\(set.assetName).png")
    if let dark = set.dark {
        write(render(dark, size: 1024), to: "\(directory)/\(set.assetName)-Dark.png")
    }
    if let tinted = set.tinted {
        write(render(tinted, size: 1024), to: "\(directory)/\(set.assetName)-Tinted.png")
    }
    write(contents: appIconContents(set), to: "\(directory)/Contents.json")

    // The preview. A transparent palette gets the backdrop iOS would have
    // supplied, so the row shows what the home screen will actually show.
    let previewName = "\(set.assetName)Preview"
    let previewDirectory = "\(catalogue)/\(previewName).imageset"
    makeDirectory(previewDirectory)

    var preview = set.previewOverride ?? set.base
    if preview.background == nil { preview.background = systemDarkBackground }
    write(render(preview, size: previewSize), to: "\(previewDirectory)/\(previewName).png")

    // Only the adaptive icon changes with the system, so only its preview does.
    if var dark = set.dark {
        if dark.background == nil { dark.background = systemDarkBackground }
        write(render(dark, size: previewSize), to: "\(previewDirectory)/\(previewName)-Dark.png")
    }
    write(contents: previewContents(previewName, hasDark: set.dark != nil),
          to: "\(previewDirectory)/Contents.json")

    print("wrote \(set.assetName) (+ preview)")
}
