// Lists after the app comes back to the front. A reader reported a list that no longer scrolled
// after a return (other taps worked; a new list did scroll), not reproduced on a simulator. This
// logs each list's scroll state on every return, clears what a return can leave in flight, and
// logs the state again when a drag soon after a return leaves its list where it was.
//
// The log: subsystem the app's bundle id, category `scroll-return`; numbers only, no text of the
// app's. Collect it from a paired phone with `log collect --device-udid <udid> --last 1h` and read
// it with `log show <archive> --predicate 'category == "scroll-return"'`. The same lines go to
// `Library/Caches/scroll-return.log` in the app's container (kept under 256 KB), which
// `xcrun devicectl device copy from --domain-type appDataContainer` reads without root.
//
// Besides each list, the first drags after a return log every gesture recognizer that heard the
// finger (its class, state and view), and any recognizer in the window still active: a freeze
// where every drag dies (lists, sideways swipes, the back swipe) while taps work points at one
// gesture that the others wait on.
#if os(iOS)
import os
import UIKit

final class ScrollReturn: NSObject {
    /// How long after a return a drag that moves nothing is logged.
    static let watch: CFTimeInterval = 1800
    /// Drags logged with their recognizers after each return.
    static let dragsLogged = 8
    /// A drag that leaves its list where it was: at least this far, and the offset within this.
    static let travel: CGFloat = 30, still: CGFloat = 1

    let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "exact", category: "scroll-return")
    private static let file: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("scroll-return.log")
    private var drags = 0

    /// One line to the unified log and to the file, stamped with the wall clock.
    private func note(_ text: String) {
        log.notice("\(text, privacy: .public)")
        guard let url = Self.file else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) \(text)\n".utf8)
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int), size > 256_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
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
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.leaving("resign")
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.leaving("background")
        })
        note("watching")
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
        note("\(why) return=\(returns) list=\(id) window=\(scroll.window != nil) hidden=\(node.isHidden || scroll.isHidden) enabled=\(scroll.isScrollEnabled) user=\(scroll.isUserInteractionEnabled) pan=\(pan.state.rawValue)/\(pan.isEnabled) tracking=\(scroll.isTracking) dragging=\(scroll.isDragging) decelerating=\(scroll.isDecelerating) size=\(Self.num(size.width))x\(Self.num(size.height)) bounds=\(Self.num(bounds.width))x\(Self.num(bounds.height)) offset=\(Self.num(offset.x)),\(Self.num(offset.y)) inset=\(Self.num(inset.top)),\(Self.num(inset.bottom)) correction=\(driver) animating=\(animating) pinned=\(pinned)")
    }

    /// The scene is active again: each list's state, then what was left in flight cleared. Nothing
    /// that is not stuck changes: a correction is cancelled where it stands (no jump), the pin
    /// only goes when one is held (no touch can be down now), and an open swipe stays open.
    /// Recognizers still in began/changed are force-ended: a phone freeze left
    /// `_UIFlexInteractionPanGestureRecognizer` (and sometimes the interactive-back pan) in
    /// `.changed` with no finger down, so every other pan waited on it until a tab remount.
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
        let released = releaseStuck("return")
        note("cleared return=\(returns) corrections=\(corrections) pin=\(pinned) swipes-projected=\(swipes.projected) swipes-released=\(swipes.released) recognizers-released=\(released)")
        drags = 0
        active("return")
    }

    /// Force-end every window recognizer still in began/changed (except this probe). Toggling
    /// `isEnabled` cancels UIKit's gesture; needed for system pans that never leave `.changed`
    /// after a return (liquid-glass `_UIFlexInteraction` on the window, interactive-back parallax).
    @discardableResult
    private func releaseStuck(_ why: StaticString) -> Int {
        guard let window = viewport?.window else { return 0 }
        var released = 0
        var stack: [UIView] = [window]
        while let v = stack.popLast() {
            for g in v.gestureRecognizers ?? [] where g.state == .began || g.state == .changed {
                if g === probe { continue }
                note("release \(why) \(Self.describe(g))")
                g.isEnabled = false
                g.isEnabled = true
                released += 1
            }
            stack.append(contentsOf: v.subviews)
        }
        if released > 0 { note("released \(why) return=\(returns) count=\(released)") }
        return released
    }

    /// The app is leaving the front: each list, and any recognizer still active.
    private func leaving(_ why: StaticString) {
        for (id, node, scroll) in lists { line(why, id, node, scroll) }
        active(why)
    }

    private static func num(_ v: CGFloat) -> String { String(format: "%.1f", Double(v)) }

    /// A recognizer as one word: its class, state, enabled, and its view (a node's id).
    private static func describe(_ g: UIGestureRecognizer) -> String {
        let view = g.view.map { v in (v as? NodeView).map { "node\($0.id)" } ?? String(describing: type(of: v)) } ?? "none"
        let delegate = g.delegate.map { String(describing: type(of: $0)) } ?? "-"
        return "\(type(of: g))[state=\(g.state.rawValue) on=\(g.isEnabled) view=\(view) delegate=\(delegate) cancels=\(g.cancelsTouchesInView)]"
    }

    /// Every recognizer in the window that is active (began or changed).
    private func active(_ why: StaticString) {
        guard let window = viewport?.window else { note("active \(why) no-window"); return }
        var found: [String] = []
        var stack: [UIView] = [window]
        while let v = stack.popLast() {
            for g in v.gestureRecognizers ?? [] where g.state == .began || g.state == .changed {
                found.append(Self.describe(g))
            }
            stack.append(contentsOf: v.subviews)
        }
        note("active \(why) return=\(returns) key=\(window.isKeyWindow) user=\(window.isUserInteractionEnabled) scene=\(window.windowScene?.activationState.rawValue ?? -1) count=\(found.count) \(found.joined(separator: " "))")
    }

    // MARK: A drag that moves nothing

    private var start: (point: CGPoint, offsets: [UInt32: CGPoint])?

    fileprivate func began(_ point: CGPoint) {
        guard returns > 0, CACurrentMediaTime() - returnedAt < Self.watch else { start = nil; return }
        start = (point, Dictionary(uniqueKeysWithValues: lists.map { ($0.0, $0.2.contentOffset) }))
    }

    /// The first drags after a return, moved or not: where, how far, whether a list moved, and
    /// every recognizer that heard the finger, as it stands when the finger lifts.
    fileprivate func drag(_ touch: UITouch, from: CGPoint, to: CGPoint, how: StaticString) {
        guard returns > 0, CACurrentMediaTime() - returnedAt < Self.watch, drags < Self.dragsLogged,
              max(abs(to.x - from.x), abs(to.y - from.y)) >= Self.travel else { return }
        drags += 1
        let moved = lists.contains { id, _, scroll in
            guard let before = start?.offsets[id] else { return false }
            return abs(scroll.contentOffset.x - before.x) >= Self.still || abs(scroll.contentOffset.y - before.y) >= Self.still
        }
        let heard = (touch.gestureRecognizers ?? []).map(Self.describe).joined(separator: " ")
        note("drag \(how) return=\(returns) n=\(drags) from=\(Self.num(from.x)),\(Self.num(from.y)) by=\(Self.num(to.x - from.x)),\(Self.num(to.y - from.y)) moved=\(moved) since=\(Self.num(CGFloat(CACurrentMediaTime() - returnedAt))) heard=\(heard)")
        if !moved {
            active("drag")
            // Finger is up; a pan still in began/changed is what freezes every later drag
            // (phone log: `_UIFlexInteractionPanGestureRecognizer` stayed `.changed`).
            releaseStuck("drag")
        }
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
        private var from: CGPoint = .zero
        override init(target: Any? = nil, action: Selector? = nil) {
            super.init(target: target, action: action)
            cancelsTouchesInView = false; delaysTouchesBegan = false; delaysTouchesEnded = false
        }
        override func canPrevent(_ other: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by other: UIGestureRecognizer) -> Bool { false }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            guard touch == nil, let first = touches.first, let view else { return }
            touch = first
            from = first.location(in: view)
            owner?.began(from)
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            guard let touch, touches.contains(touch), let view else { return }
            owner?.drag(touch, from: from, to: touch.location(in: view), how: "ended")
            owner?.ended(touch.location(in: view))
            self.touch = nil
            state = .failed
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            // A touch the system took (an app switch) is no drag of the reader's.
            if let touch, touches.contains(touch), let view {
                owner?.drag(touch, from: from, to: touch.location(in: view), how: "cancelled")
            }
            touch = nil
            state = .failed
        }
        override func reset() { super.reset(); touch = nil }
    }
}
#endif
