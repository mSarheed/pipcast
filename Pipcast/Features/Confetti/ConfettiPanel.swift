import AppKit

/// A click-through sheet over one display; every burst adds a cannon to each bottom corner.
final class ConfettiPanel: NSPanel {
    private enum Shape: CaseIterable {
        case strip, triangle, circle

        /// Mostly strips, as Raycast's is: the triangles and dots only salt it.
        var birthRate: Float {
            switch self {
            case .strip: 130
            case .triangle: 45
            case .circle: 35
            }
        }
    }

    private static let colors: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple,
        .systemPink
    ]
    /// How long the cannons fire; everything after is the flutter and the fall.
    private static let firing: CFTimeInterval = 0.25
    /// From a burst's first piece to its last one leaving the display.
    static let lifetime: Duration = .seconds(3)

    /// Runs once the last burst in the air has fallen, so the owner can close the sheet.
    var onEmpty: (() -> Void)?

    private let host: NSView
    private let pixelScale: CGFloat
    /// Drawn once per sheet, since every burst and colour shares them.
    private let images: [Shape: CGImage]
    private var falls: [Int: Task<Void, Never>] = [:]
    private var nextFall = 0

    init(screen: NSScreen) {
        let frame = screen.frame
        host = NSView(frame: NSRect(origin: .zero, size: frame.size))
        host.wantsLayer = true
        pixelScale = screen.backingScaleFactor
        images = Shape.allCases.reduce(into: [:]) { images, shape in
            images[shape] = Self.image(of: shape, scale: screen.backingScaleFactor)
        }
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
        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Adds to whatever is still in the air rather than replacing it, as Raycast's does.
    func fire() {
        guard let root = host.layer else { return }
        let bounds = host.bounds
        let cannons = [
            cannon(at: CGPoint(x: 0, y: 0), aim: .pi / 2 - 0.5, in: bounds),
            cannon(at: CGPoint(x: bounds.width, y: 0), aim: .pi / 2 + 0.5, in: bounds)
        ]
        for cannon in cannons { root.addSublayer(cannon) }
        let fall = nextFall
        nextFall += 1
        falls[fall] = Task { [weak self] in
            try? await Task.sleep(for: Self.lifetime)
            guard !Task.isCancelled, let self else { return }
            for cannon in cannons { cannon.removeFromSuperlayer() }
            falls[fall] = nil
            if falls.isEmpty { onEmpty?() }
        }
    }

    override func close() {
        for fall in falls.values { fall.cancel() }
        falls.removeAll()
        super.close()
    }

    private func cannon(at point: CGPoint, aim: CGFloat, in bounds: CGRect) -> CAEmitterLayer {
        let emitter = CAEmitterLayer()
        emitter.frame = bounds
        emitter.emitterPosition = point
        emitter.emitterShape = .point
        emitter.renderMode = .unordered
        emitter.beginTime = CACurrentMediaTime()
        emitter.birthRate = 0
        // Speed and gravity scale with the display, so the burst reaches the top on any screen.
        let height = bounds.height
        var cells: [CAEmitterCell] = []
        for shape in Shape.allCases {
            guard let image = images[shape] else { continue }
            for color in Self.colors {
                let cell = Self.piece(
                    shape, image: image, scale: pixelScale, color: color, aim: aim, height: height)
                cell.name = "confetti-\(cells.count)"
                cells.append(cell)
            }
        }
        emitter.emitterCells = cells
        Self.addAir(to: emitter)

        let firing = CABasicAnimation(keyPath: "birthRate")
        firing.fromValue = 1
        firing.toValue = 0
        firing.duration = Self.firing
        emitter.add(firing, forKey: "firing")

        let gravity = CAKeyframeAnimation()
        gravity.duration = CFTimeInterval(Self.lifetime.components.seconds)
        gravity.keyTimes = [0, 0.15, 0.5, 1]
        gravity.values = [0, -0.2 * height, -1.2 * height, -2.4 * height].map { $0 as NSNumber }
        gravity.fillMode = .forwards
        gravity.isRemovedOnCompletion = false
        for cell in cells {
            guard let name = cell.name else { continue }
            let keyPath = "emitterCells.\(name).yAcceleration"
            gravity.keyPath = keyPath
            emitter.add(gravity, forKey: keyPath)
        }
        return emitter
    }

    private static func piece(
        _ shape: Shape, image: CGImage, scale: CGFloat, color: NSColor, aim: CGFloat,
        height: CGFloat
    ) -> CAEmitterCell {
        let cell = CAEmitterCell()
        cell.contents = image
        cell.contentsScale = scale
        cell.color = color.cgColor
        cell.birthRate = shape.birthRate
        cell.lifetime = 2.1
        cell.lifetimeRange = 0.7
        cell.velocity = height * 3.4
        cell.velocityRange = height * 1.6
        cell.emissionLongitude = aim
        cell.emissionRange = 0.6
        cell.spin = 4
        cell.spinRange = 8
        cell.scaleRange = 0.25
        // Undocumented: a plane tumbles through three axes like paper; missing, it spins flat.
        cell.setValue("plane", forKey: "particleType")
        cell.setValue(Double.pi, forKey: "orientationRange")
        cell.setValue(Double.pi / 2, forKey: "orientationLongitude")
        cell.setValue(Double.pi / 2, forKey: "orientationLatitude")
        return cell
    }

    /// The launch is tuned for this drag to brake it short of the top; without it, it overshoots.
    private static func addAir(to emitter: CAEmitterLayer) {
        let drag = behavior("drag")
        drag?.setValue("drag", forKey: "name")
        drag?.setValue(2.6, forKey: "drag")
        let sway = behavior("wave")
        sway?.setValue([90, 0, 0], forKey: "force")
        sway?.setValue(0.5, forKey: "frequency")
        let flutter = behavior("wave")
        flutter?.setValue([0, 400, 0], forKey: "force")
        flutter?.setValue(3, forKey: "frequency")
        let behaviors = [drag, sway, flutter].compactMap { $0 }
        guard !behaviors.isEmpty else { return }
        emitter.setValue(behaviors, forKey: "emitterBehaviors")
    }

    /// `CAEmitterBehavior` is private, so it is looked up at run time and may be absent.
    private static func behavior(_ type: String) -> NSObject? {
        let selector = NSSelectorFromString("behaviorWithType:")
        guard let behaviorClass = NSClassFromString("CAEmitterBehavior") as? NSObject.Type,
            class_getClassMethod(behaviorClass, selector) != nil
        else { return nil }
        typealias Make = @convention(c) (AnyObject, Selector, NSString) -> NSObject?
        let make = unsafeBitCast(behaviorClass.method(for: selector), to: Make.self)
        return make(behaviorClass, selector, type as NSString)
    }

    /// White, so each cell's colour tints it.
    private static func image(of shape: Shape, scale: CGFloat) -> CGImage? {
        let size: CGSize =
            switch shape {
            case .strip: CGSize(width: 16, height: 5)
            case .triangle: CGSize(width: 9, height: 8)
            case .circle: CGSize(width: 6, height: 6)
            }
        let width = Int(size.width * scale)
        let height = Int(size.height * scale)
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        switch shape {
        case .strip: context.fill(rect)
        case .circle: context.fillEllipse(in: rect)
        case .triangle:
            context.move(to: CGPoint(x: rect.minX, y: rect.minY))
            context.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            context.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            context.fillPath()
        }
        return context.makeImage()
    }
}
