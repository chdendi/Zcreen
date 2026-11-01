import CoreGraphics

extension CGRect {
    /// Every edge of `self` lies within `tolerance` points of the matching edge of `other`.
    func isClose(to other: CGRect, tolerance: CGFloat) -> Bool {
        abs(origin.x - other.origin.x) <= tolerance &&
            abs(origin.y - other.origin.y) <= tolerance &&
            abs(width - other.width) <= tolerance &&
            abs(height - other.height) <= tolerance
    }
}
