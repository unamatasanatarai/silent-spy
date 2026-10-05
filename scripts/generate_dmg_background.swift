import AppKit
import CoreGraphics

func renderDMGBackground(scale: CGFloat) -> Data {
    let width: CGFloat = 640
    let height: CGFloat = 420

    let pixelWidth = Int(width * scale)
    let pixelHeight = Int(height * scale)

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: pixelWidth,
        height: pixelHeight,
        bitsPerComponent: 8,
        bytesPerRow: pixelWidth * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("Could not create CGContext")
    }

    context.scaleBy(x: scale, y: scale)

    func fy(_ y: CGFloat) -> CGFloat {
        return height - y
    }

    // 1. Deep Midnight / Slate Navy Gradient (Matches Leaf App Icon)
    context.setFillColor(CGColor(red: 0.05, green: 0.07, blue: 0.11, alpha: 1.0))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    let glowColors: [CGColor] = [
        CGColor(red: 0.18, green: 0.24, blue: 0.38, alpha: 1.0), // Center highlight #2e3d61
        CGColor(red: 0.11, green: 0.15, blue: 0.25, alpha: 1.0), // Mid navy #1c2640
        CGColor(red: 0.05, green: 0.07, blue: 0.11, alpha: 1.0)  // Edge dark #0d121c
    ]
    let glowLocations: [CGFloat] = [0.0, 0.55, 1.0]
    if let glowGradient = CGGradient(colorsSpace: colorSpace, colors: glowColors as CFArray, locations: glowLocations) {
        let center = CGPoint(x: width * 0.5, y: fy(height * 0.46))
        context.drawRadialGradient(
            glowGradient,
            startCenter: center,
            startRadius: 0,
            endCenter: center,
            endRadius: width * 0.70,
            options: [.drawsAfterEndLocation, .drawsBeforeStartLocation]
        )
    }

    // Top subtle glass highlight line
    let rimColors: [CGColor] = [
        CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.15),
        CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.0)
    ]
    if let rimGradient = CGGradient(colorsSpace: colorSpace, colors: rimColors as CFArray, locations: [0.0, 1.0]) {
        context.drawLinearGradient(
            rimGradient,
            start: CGPoint(x: 0, y: fy(0)),
            end: CGPoint(x: 0, y: fy(40)),
            options: []
        )
    }

    // 2. Soft Leaf Watermark (Radially Blended)
    if let iconImage = NSImage(contentsOfFile: "Resources/leaf-app-icon.png"),
       let cgIcon = iconImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
        context.saveGState()
        let iconSize: CGFloat = 200
        let iconRect = CGRect(x: (width - iconSize) / 2, y: fy(215 + iconSize / 2), width: iconSize, height: iconSize)
        context.setAlpha(0.12)
        context.draw(cgIcon, in: iconRect)
        context.restoreGState()
    }

    // 3. Typography: "Need receipts? Leaf it to me!"
    let titleY: CGFloat = 62

    let titleFont1 = NSFont.systemFont(ofSize: 25, weight: .bold)
    let titleFont2 = NSFont.systemFont(ofSize: 25, weight: .heavy)

    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.alignment = .center

    let textShadow = NSShadow()
    textShadow.shadowColor = NSColor.black.withAlphaComponent(0.75)
    textShadow.shadowOffset = NSSize(width: 0, height: -2)
    textShadow.shadowBlurRadius = 8

    let fullAttrString = NSMutableAttributedString()

    let part1 = NSAttributedString(string: "Need receipts? ", attributes: [
        .font: titleFont1,
        .foregroundColor: NSColor.white,
        .shadow: textShadow,
        .paragraphStyle: paragraphStyle
    ])

    let part2 = NSAttributedString(string: "Leaf it to me!", attributes: [
        .font: titleFont2,
        .foregroundColor: NSColor(red: 0.85, green: 0.94, blue: 1.0, alpha: 1.0),
        .shadow: textShadow,
        .paragraphStyle: paragraphStyle
    ])

    fullAttrString.append(part1)
    fullAttrString.append(part2)

    let titleSize = fullAttrString.size()
    let titleRect = CGRect(x: (width - titleSize.width) / 2, y: fy(titleY + titleSize.height), width: titleSize.width, height: titleSize.height)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    fullAttrString.draw(in: titleRect)

    // Subtitle instruction below the title: "Drag SilentSpy to Applications"
    let subFont = NSFont.systemFont(ofSize: 12.5, weight: .medium)
    let subAttr = NSAttributedString(string: "Drag to Applications to install", attributes: [
        .font: subFont,
        .foregroundColor: NSColor.white.withAlphaComponent(0.48),
        .paragraphStyle: paragraphStyle
    ])
    let subSize = subAttr.size()
    let subY: CGFloat = titleY + titleSize.height + 6
    let subRect = CGRect(x: (width - subSize.width) / 2, y: fy(subY + subSize.height), width: subSize.width, height: subSize.height)

    subAttr.draw(in: subRect)
    NSGraphicsContext.restoreGraphicsState()

    // 4. Dynamic Modern Directional Arrows
    let arrowCenterY = fy(210)

    context.saveGState()

    let chevronData: [(x: CGFloat, size: CGFloat, alpha: CGFloat, thickness: CGFloat)] = [
        (x: 275, size: 14, alpha: 0.30, thickness: 3.2),
        (x: 320, size: 18, alpha: 0.65, thickness: 3.8),
        (x: 365, size: 22, alpha: 1.00, thickness: 4.5)
    ]

    for item in chevronData {
        context.saveGState()
        if item.alpha > 0.5 {
            context.setShadow(
                offset: .zero,
                blur: 8,
                color: CGColor(red: 0.7, green: 0.85, blue: 1.0, alpha: item.alpha * 0.5)
            )
        }
        
        let path = CGMutablePath()
        let s = item.size
        path.move(to: CGPoint(x: item.x - s * 0.55, y: arrowCenterY + s * 0.85))
        path.addLine(to: CGPoint(x: item.x + s * 0.45, y: arrowCenterY))
        path.addLine(to: CGPoint(x: item.x - s * 0.55, y: arrowCenterY - s * 0.85))
        
        context.setStrokeColor(CGColor(red: 0.88, green: 0.94, blue: 1.0, alpha: item.alpha))
        context.setLineWidth(item.thickness)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addPath(path)
        context.strokePath()
        
        context.restoreGState()
    }

    let leadPath = CGMutablePath()
    leadPath.move(to: CGPoint(x: 235, y: arrowCenterY))
    leadPath.addLine(to: CGPoint(x: 260, y: arrowCenterY))
    context.setStrokeColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.18))
    context.setLineWidth(2.5)
    context.setLineCap(.round)
    context.addPath(leadPath)
    context.strokePath()

    context.restoreGState()

    guard let finalImage = context.makeImage() else {
        fatalError("Failed to make final image")
    }

    let rep = NSBitmapImageRep(cgImage: finalImage)
    rep.size = NSSize(width: width, height: height)
    guard let pngData = rep.representation(using: .png, properties: [:]) else {
        fatalError("Failed to convert to PNG")
    }
    return pngData
}

let outputDir = "Resources/dmg"
try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

let data1x = renderDMGBackground(scale: 1.0)
let data2x = renderDMGBackground(scale: 2.0)

let outputPath = "\(outputDir)/background.png"
let output2xPath = "\(outputDir)/background@2x.png"

try data1x.write(to: URL(fileURLWithPath: outputPath))
try data2x.write(to: URL(fileURLWithPath: output2xPath))

print("✅ Successfully generated DMG background at \(outputPath) (1x) and \(output2xPath) (2x)")
