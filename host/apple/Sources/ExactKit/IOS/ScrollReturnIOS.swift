// Lists after the app comes back to the front. A reader reported a list that no longer scrolled
// after a return (other taps worked; a new list did scroll), not reproduced on a simulator. This
// logs each list's scroll state on every return, clears what a return can leave in flight, and
// logs the state again when a drag soon after a return leaves its list where it was.
//
// The log: subsystem the app's bundle id, category `scroll-return`; numbers only, no text of the
// app's. Collect it from a paired phone with `log collect --device-udid <udid> --last 1h` and read
// it with `log show <archive> --predicate 'category == "scroll-return"'`.
#if os(iOS)
import os
import UIKit

final class ScrollReturn: NSObject {
    /// How long after a return a drag that moves nothing is logged.
    static let watch: CFTimeInterval = 120
    /// A drag that leaves its list where it was: at least this far, and the offset within this.
    static let travel: CGFloat = 30, still: CGFloat = 1

    let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "exact", category: "scroll-return")
    private unowned let collections: CollectionHost
    private weak var viewport: UIView?
    private var observers: [NSObjectProtocol] = []
    private var probe: Probe?
    private var returns = 0
    private var returnedAt: CFTimeInterval = 0
    /// Lists already logged as stuck since the last return: one line a list a return.
    private var stuckLogged = Set<UInt32>()

    init(_ collections: CollectionHost, viewport: UIView) {
        self.collections = collections
        self.viewport = viewport
        super.init()
        let probe = Probe(); probe.owner = self
        viewport.addGestureRecognizer(probe)
        self.probe = probe
        // Once the app is active again: no touch can be down, and UIKit has laid the window out again.
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.returned()
        })
        log.notice("watching")
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let probe { probe.view?.removeGestureRecognizer(probe) }
        probe = nil
    }

    private var lists: [(UInt32, NodeView, UIScrollView)] {
        (collections.presenter?.listViews ?? [:]).compactMap { id, node in node.scroll.map { (id, node, $0) } }.sorted { $0.0 < $1.0 }
    }

    /// One list's scroll state, as one line: numbers and flags only.
    private func line(_ why: StaticString, _ id: UInt32, _ node: NodeView, _ scroll: UIScrollView) {
        let pan = scroll.panGestureRecognizer
        let size = scroll.contentSize, bounds = scroll.bounds.size, offset = scroll.contentOffset, inset = scroll.adjustedContentInset
        let driver = collections.offsetDrivers[id] != nil, animating = collections.animating.contains(id)
        let pinned = collections.interaction != nil
        log.notice("\(why, privacy: .public) return=\(self.returns) list=\(id) window=\(scroll.window != nil) hidden=\(node.isHidden || scroll.isHidden) enabled=\(scroll.isScrollEnabled) user=\(scroll.isUserInteractionEnabled) pan=\(pan.state.rawValue)/\(pan.isEnabled) tracking=\(scroll.isTracking) dragging=\(scroll.isDragging) decelerating=\(scroll.isDecelerating) size=\(Double(size.width), format: .fixed(precision: 1))x\(Double(size.height), format: .fixed(precision: 1)) bounds=\(Double(bounds.width), format: .fixed(precision: 1))x\(Double(bounds.height), format: .fixed(precision: 1)) offset=\(Double(offset.x), format: .fixed(precision: 1)),\(Double(offset.y), format: .fixed(precision: 1)) inset=\(Double(inset.top), format: .fixed(precision: 1)),\(Double(inset.bottom), format: .fixed(precision: 1)) correction=\(driver) animating=\(animating) pinned=\(pinned)")
    }

    /// The scene is active again: each list's state, then what was left in flight cleared. Nothing
    /// that is not stuck changes: a correction is cancelled where it stands (no jump), the pin
    /// only goes when one is held (no touch can be down now), and an open swipe stays open.
    private func returned() {
        returns += 1
        returnedAt = CACurrentMediaTime()
        stuckLogged = []
        for (id, node, scroll) in lists { line("return", id, node, scroll) }
        var corrections = 0
        for id in Array(collections.offsetDrivers.keys) {
            collections.stopAnimation(id)
            collections.reportAgain(id)
            corrections += 1
        }
        let pinned = collections.interaction != nil
        if pinned { collections.pointer(nil) }
        let swipes = collections.presenter?.swipeActions.returned() ?? (projected: 0, released: 0)
        log.notice("cleared return=\(self.returns) corrections=\(corrections) pin=\(pinned) swipes-projected=\(swipes.projected) swipes-released=\(swipes.released)")
    }

    // MARK: A drag that moves nothing

    private var start: (point: CGPoint, offsets: [UInt32: CGPoint])?

    fileprivate func began(_ point: CGPoint) {
        guard returns > 0, CACurrentMediaTime() - returnedAt < Self.watch else { start = nil; return }
        start = (point, Dictionary(uniqueKeysWithValues: lists.map { ($0.0, $0.2.contentOffset) }))
    }

    fileprivate func ended(_ point: CGPoint) {
        guard let start, let viewport else { return }
        self.start = nil
        guard abs(point.y - start.point.y) >= Self.travel else { return }
        for (id, node, scroll) in lists where !stuckLogged.contains(id) && scroll.window != nil {
            // The list the drag began in.
            guard scroll.convert(scroll.bounds, to: viewport).contains(start.point), let before = start.offsets[id] else { continue }
            let now = scroll.contentOffset
            guard abs(now.x - before.x) < Self.still, abs(now.y - before.y) < Self.still else { continue }
            stuckLogged.insert(id)
            line("stuck", id, node, scroll)
        }
    }

    /// Watches touches on the window and never recognizes: it neither delays nor takes them.
    private final class Probe: UIGestureRecognizer {
        weak var owner: ScrollReturn?
        private weak var touch: UITouch?
        override init(target: Any? = nil, action: Selector? = nil) {
            super.init(target: target, action: action)
            cancelsTouchesInView = false; delaysTouchesBegan = false; delaysTouchesEnded = false
        }
        override func canPrevent(_ other: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by other: UIGestureRecognizer) -> Bool { false }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            guard touch == nil, let first = touches.first, let view else { return }
            touch = first
            owner?.began(first.location(in: view))
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            guard let touch, touches.contains(touch), let view else { return }
            owner?.ended(touch.location(in: view))
            self.touch = nil
            state = .failed
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            // A touch the system took (an app switch) is no drag of the reader's.
            touch = nil
            state = .failed
        }
        override func reset() { super.reset(); touch = nil }
    }
}
#endif
