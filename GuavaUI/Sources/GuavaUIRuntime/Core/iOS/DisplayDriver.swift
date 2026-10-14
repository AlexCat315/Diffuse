#if os(iOS)
import UIKit

/// Returns to UIKit after each frame so Core Animation can commit Metal layers.
@MainActor
final class IOSFrameDriver: NSObject {
    private let frame: () -> Bool
    private var link: CADisplayLink?
    init(frame: @escaping () -> Bool) { self.frame = frame }
    func start() {
        let link = CADisplayLink(target: self, selector: #selector(tick))
        self.link = link
        link.add(to: .main, forMode: .common)
    }
    func stop() { link?.invalidate(); link = nil }
    @objc private func tick() { if !frame() { stop() } }
}
#endif
