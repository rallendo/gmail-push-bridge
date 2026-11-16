import AppKit

func makeLogo(size: Int, filename: String) {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: size * 4,
        bitsPerPixel: 32
    )!

    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext

    // Background squircle
    let rect = CGRect(x: 0, y: 0, width: s, height: s)
    let margin = s * 0.05
    let corner = s * 0.22
    let bgRect = rect.insetBy(dx: margin, dy: margin)
    let path = CGPath(roundedRect: bgRect, cornerWidth: corner, cornerHeight: corner, transform: nil)

    // Gradient background: Deep indigo / Slate to Charcoal
    let colors = [
        NSColor(red: 0.10, green: 0.12, blue: 0.22, alpha: 1.0).cgColor,
        NSColor(red: 0.15, green: 0.25, blue: 0.45, alpha: 1.0).cgColor
    ] as CFArray
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 1.0])!
    
    cg.addPath(path)
    cg.clip()
    cg.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])

    // Border highlight
    cg.setStrokeColor(NSColor(white: 1.0, alpha: 0.2).cgColor)
    cg.setLineWidth(s * 0.02)
    cg.addPath(path)
    cg.strokePath()

    // Draw stylized envelope in the center
    let envW = s * 0.58
    let envH = s * 0.40
    let envX = (s - envW) / 2.0
    let envY = (s - envH) / 2.0 - (s * 0.03)
    let envRect = CGRect(x: envX, y: envY, width: envW, height: envH)
    let envCorner = s * 0.05

    // Envelope body
    let envPath = CGPath(roundedRect: envRect, cornerWidth: envCorner, cornerHeight: envCorner, transform: nil)
    cg.setFillColor(NSColor.white.cgColor)
    cg.addPath(envPath)
    cg.fillPath()

    // Envelope flap accent lines (Gmail red/blue/amber accent feel)
    // Red flap V
    let flapPath = CGMutablePath()
    flapPath.move(to: CGPoint(x: envX, y: envY + envH))
    flapPath.addLine(to: CGPoint(x: envX + envW / 2.0, y: envY + envH * 0.42))
    flapPath.addLine(to: CGPoint(x: envX + envW, y: envY + envH))
    cg.setStrokeColor(NSColor(red: 0.92, green: 0.26, blue: 0.21, alpha: 1.0).cgColor) // Google Red
    cg.setLineWidth(s * 0.04)
    cg.setLineCap(.round)
    cg.setLineJoin(.round)
    cg.addPath(flapPath)
    cg.strokePath()

    // Side folds
    let foldLeft = CGMutablePath()
    foldLeft.move(to: CGPoint(x: envX, y: envY))
    foldLeft.addLine(to: CGPoint(x: envX + envW * 0.40, y: envY + envH * 0.48))
    cg.setStrokeColor(NSColor(red: 0.26, green: 0.52, blue: 0.96, alpha: 0.85).cgColor) // Google Blue
    cg.setLineWidth(s * 0.03)
    cg.addPath(foldLeft)
    cg.strokePath()

    let foldRight = CGMutablePath()
    foldRight.move(to: CGPoint(x: envX + envW, y: envY))
    foldRight.addLine(to: CGPoint(x: envX + envW * 0.60, y: envY + envH * 0.48))
    cg.setStrokeColor(NSColor(red: 0.20, green: 0.66, blue: 0.33, alpha: 0.85).cgColor) // Google Green
    cg.setLineWidth(s * 0.03)
    cg.addPath(foldRight)
    cg.strokePath()

    // Golden lightning bolt for "Instant Push" in top right
    let bolt = CGMutablePath()
    let bx = s * 0.66
    let by = s * 0.52
    let bw = s * 0.24
    let bh = s * 0.38
    bolt.move(to: CGPoint(x: bx + bw * 0.65, y: by + bh))
    bolt.addLine(to: CGPoint(x: bx, y: by + bh * 0.45))
    bolt.addLine(to: CGPoint(x: bx + bw * 0.45, y: by + bh * 0.45))
    bolt.addLine(to: CGPoint(x: bx + bw * 0.25, y: by))
    bolt.addLine(to: CGPoint(x: bx + bw, y: by + bh * 0.55))
    bolt.addLine(to: CGPoint(x: bx + bw * 0.55, y: by + bh * 0.55))
    bolt.closeSubpath()

    // Bolt drop shadow
    cg.setShadow(offset: CGSize(width: 0, height: -2), blur: s * 0.04, color: NSColor.black.withAlphaComponent(0.4).cgColor)
    cg.setFillColor(NSColor(red: 0.98, green: 0.75, blue: 0.18, alpha: 1.0).cgColor) // Amber gold
    cg.addPath(bolt)
    cg.fillPath()

    // Bolt stroke
    cg.setStrokeColor(NSColor.white.cgColor)
    cg.setLineWidth(s * 0.02)
    cg.addPath(bolt)
    cg.strokePath()

    NSGraphicsContext.restoreGraphicsState()

    if let pngData = rep.representation(using: .png, properties: [:]) {
        let url = URL(fileURLWithPath: filename)
        try? pngData.write(to: url)
        print("Generated \(filename) (\(size)x\(size), \(pngData.count) bytes)")
    }
}

makeLogo(size: 120, filename: "logo-120.png")
makeLogo(size: 512, filename: "logo-512.png")
