import UIKit

/// The mouse pointer drawn on the external display.
final class CursorView: UIView {
    private let shape = CAShapeLayer()
    private let imageView = UIImageView()
    private(set) var kind: CursorKind = .arrow
    /// Offset from the view's origin to the pointer's hot spot.
    private var hotspot: CGPoint = .zero
    private var lastLocation: CGPoint = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.addSublayer(shape)
        shape.lineJoin = .round
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.35
        layer.shadowRadius = 2
        layer.shadowOffset = CGSize(width: 0, height: 1)
        imageView.contentMode = .center
        imageView.tintColor = .white
        imageView.layer.shadowColor = UIColor.black.cgColor
        imageView.layer.shadowOpacity = 1
        imageView.layer.shadowRadius = 1.2
        imageView.layer.shadowOffset = .zero
        addSubview(imageView)
        apply(.arrow)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setKind(_ newKind: CursorKind) {
        guard newKind != kind else { return }
        apply(newKind)
        place(at: lastLocation)
    }

    func refreshForTheme() {
        apply(kind)
        place(at: lastLocation)
    }

    func place(at point: CGPoint) {
        lastLocation = point
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame.origin = CGPoint(x: point.x - hotspot.x, y: point.y - hotspot.y)
        CATransaction.commit()
    }

    private func apply(_ newKind: CursorKind) {
        kind = newKind
        let scale = Theme.scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        func symbolCursor(_ name: String, pointSize: CGFloat, hotspotRatio: CGPoint) -> Bool {
            let configuration = UIImage.SymbolConfiguration(pointSize: pointSize * scale, weight: .bold)
            guard let image = UIImage(systemName: name, withConfiguration: configuration) else { return false }
            shape.isHidden = true
            imageView.isHidden = false
            imageView.image = image
            let size = CGSize(width: ceil(image.size.width) + 4, height: ceil(image.size.height) + 4)
            bounds = CGRect(origin: .zero, size: size)
            imageView.frame = bounds
            hotspot = CGPoint(x: size.width * hotspotRatio.x, y: size.height * hotspotRatio.y)
            return true
        }

        switch newKind {
        case .hand:
            if symbolCursor("hand.point.up.left.fill", pointSize: 17, hotspotRatio: CGPoint(x: 0.3, y: 0.08)) { return }
        case .resizeHorizontal:
            if symbolCursor("arrow.left.and.right", pointSize: 15, hotspotRatio: CGPoint(x: 0.5, y: 0.5)) { return }
        case .resizeVertical:
            if symbolCursor("arrow.up.and.down", pointSize: 15, hotspotRatio: CGPoint(x: 0.5, y: 0.5)) { return }
        case .resizeDiagonalDown:
            if symbolCursor("arrow.up.left.and.arrow.down.right", pointSize: 15, hotspotRatio: CGPoint(x: 0.5, y: 0.5)) { return }
        case .resizeDiagonalUp:
            if symbolCursor("arrow.up.right.and.arrow.down.left", pointSize: 15, hotspotRatio: CGPoint(x: 0.5, y: 0.5)) { return }
        case .move:
            if symbolCursor("arrow.up.and.down.and.arrow.left.and.right", pointSize: 16, hotspotRatio: CGPoint(x: 0.5, y: 0.5)) { return }
        case .text:
            drawIBeam(scale: scale)
            return
        case .arrow:
            break
        }
        drawArrow(scale: scale)
    }

    private func drawArrow(scale: CGFloat) {
        imageView.isHidden = true
        shape.isHidden = false
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 1, y: 1))
        path.addLine(to: CGPoint(x: 1, y: 17.5))
        path.addLine(to: CGPoint(x: 5.2, y: 13.6))
        path.addLine(to: CGPoint(x: 8, y: 19.8))
        path.addLine(to: CGPoint(x: 10.7, y: 18.6))
        path.addLine(to: CGPoint(x: 8, y: 12.6))
        path.addLine(to: CGPoint(x: 13.4, y: 12.6))
        path.close()
        path.apply(CGAffineTransform(scaleX: scale, y: scale))
        shape.path = path.cgPath
        shape.fillColor = UIColor.black.cgColor
        shape.strokeColor = UIColor.white.cgColor
        shape.lineWidth = 1.4 * scale
        bounds = CGRect(x: 0, y: 0, width: 16 * scale, height: 22 * scale)
        shape.frame = bounds
        hotspot = CGPoint(x: 1 * scale, y: 1 * scale)
    }

    private func drawIBeam(scale: CGFloat) {
        imageView.isHidden = true
        shape.isHidden = false
        let path = UIBezierPath()
        // Top serif, stem and bottom serif as one filled outline.
        path.append(UIBezierPath(rect: CGRect(x: 1, y: 1, width: 7, height: 1.6)))
        path.append(UIBezierPath(rect: CGRect(x: 3.7, y: 2.6, width: 1.6, height: 13.8)))
        path.append(UIBezierPath(rect: CGRect(x: 1, y: 16.4, width: 7, height: 1.6)))
        path.apply(CGAffineTransform(scaleX: scale, y: scale))
        shape.path = path.cgPath
        shape.fillColor = UIColor.black.cgColor
        shape.strokeColor = UIColor.white.cgColor
        shape.lineWidth = 1.1 * scale
        bounds = CGRect(x: 0, y: 0, width: 9 * scale, height: 19 * scale)
        shape.frame = bounds
        hotspot = CGPoint(x: 4.5 * scale, y: 9.5 * scale)
    }
}
