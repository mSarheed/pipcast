import AppKit

/// A click-through sheet over one display, with a confetti cannon in each bottom corner.
final class ConfettiPanel: NSPanel {
    private static let colors: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemTeal, .systemBlue,
        .systemPurple, .systemPink
    ]
    /// How long the cannons fire; everything after is the fall.
    static let burst: Duration = .milliseconds(180)
    static let lifetime: Duration = .seconds(6)

    private let emitters: [CAEmitterLayer]

    init(screen: NSScreen) {
        let frame = screen.frame
        let gravity = frame.height * 0.9
        // Enough speed to reach most of the way up the display before gravity turns it.
        let speed = (2 * gravity * frame.height * 0.85).squareRoot()
        emitters = [
            Self.cannon(at: CGPoint(x: 0, y: 0), aim: .pi / 2 - 0.42, speed: speed, gravity: gravity),
            Self.cannon(
                at: CGPoint(x: frame.width, y: 0), aim: .pi / 2 + 0.42, speed: speed, gravity: gravity)
        ]
        super.init(
            contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
            defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .statusBar
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        setFrame(frame, display: false)

        let host = NSView(frame: NSRect(origin: .zero, size: frame.size))
        host.wantsLayer = true
        for emitter in emitters {
            emitter.frame = host.bounds
            emitter.contentsScale = screen.backingScaleFactor
            host.layer?.addSublayer(emitter)
        }
        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Shuts the cannons; what is in the air keeps falling.
    func ceaseFire() {
        for emitter in emitters { emitter.birthRate = 0 }
    }

    private static func cannon(
        at point: CGPoint, aim: CGFloat, speed: CGFloat, gravity: CGFloat
    ) -> CAEmitterLayer {
        let emitter = CAEmitterLayer()
        emitter.emitterPosition = point
        emitter.emitterShape = .point
        emitter.beginTime = CACurrentMediaTime()
        emitter.emitterCells = colors.flatMap { color in
            [Self.strip, Self.dot].compactMap { image in
                image.map { piece(image: $0, color: color, aim: aim, speed: speed, gravity: gravity) }
            }
        }
        return emitter
    }

    private static func piece(
        image: CGImage, color: NSColor, aim: CGFloat, speed: CGFloat, gravity: CGFloat
    ) -> CAEmitterCell {
        let cell = CAEmitterCell()
        cell.contents = image
        cell.color = color.cgColor
        cell.birthRate = 60
        cell.lifetime = 6
        cell.velocity = speed
        cell.velocityRange = speed * 0.3
        cell.emissionLongitude = aim
        cell.emissionRange = 0.4
        cell.yAcceleration = -gravity
        cell.spin = 4
        cell.spinRange = 10
        cell.scale = 1
        cell.scaleRange = 0.4
        cell.alphaSpeed = -0.12
        return cell
    }

    private static let strip = pieceImage(width: 12, height: 6, round: false)
    private static let dot = pieceImage(width: 7, height: 7, round: true)

    /// White, so each cell's colour tints it.
    private static func pieceImage(width: Int, height: Int, round: Bool) -> CGImage? {
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        if round { context.fillEllipse(in: rect) } else { context.fill(rect) }
        return context.makeImage()
    }
}
