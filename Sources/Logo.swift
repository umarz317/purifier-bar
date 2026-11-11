import AppKit

/// Purifier Bar's app icon mark.
enum Logo {
    static let top = CGColor(srgbRed: 1.0, green: 0.74, blue: 0.30, alpha: 1)
    static let bottom = CGColor(srgbRed: 0.97, green: 0.40, blue: 0.09, alpha: 1)

    /// Particles inside a round filter, shrinking left to right: dirty air in, clean air out.
    static func glyph(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let n = 7, step = rect.width / CGFloat(n), radius = rect.width / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        for row in 0..<n {
            for col in 0..<n {
                let p = CGPoint(x: rect.minX + step * (CGFloat(col) + 0.5), y: rect.minY + step * (CGFloat(row) + 0.5))
                guard hypot(p.x - center.x, p.y - center.y) <= radius - step * 0.25 else { continue }
                let t = CGFloat(col) / CGFloat(n - 1)
                let r = step * 0.36 * (1 - 0.72 * t)
                path.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            }
        }
        return path
    }

    /// Full-color app icon on Apple's 1024 grid (824pt body, ~100pt margin).
    static func drawIcon(in ctx: CGContext, size: CGFloat) {
        let body = CGRect(x: 0, y: 0, width: size, height: size).insetBy(dx: size * 0.0977, dy: size * 0.0977)
        let shape = CGPath(roundedRect: body, cornerWidth: body.width * 0.225, cornerHeight: body.width * 0.225, transform: nil)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.01), blur: size * 0.03,
                      color: CGColor(gray: 0, alpha: 0.3))
        ctx.addPath(shape)
        ctx.setFillColor(bottom)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [top, bottom] as CFArray,
                                  locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
        ctx.addPath(glyph(in: body.insetBy(dx: body.width * 0.16, dy: body.width * 0.16)))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()
    }
}
