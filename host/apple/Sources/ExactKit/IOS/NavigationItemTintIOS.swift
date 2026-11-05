#if os(iOS) || os(tvOS)
import UIKit

extension NavigationHost {
    // keep item, menu and accessibility identity across accent-only changes.
    func refreshProminentTints() {
        guard #available(iOS 26.0, tvOS 26.0, *) else { return }
        let tint = presenter.accent.effectiveTint
        for route in controllers.values {
            for made in route.barItemsMade.values where made.item.prominent && made.item.badge == nil && made.item.chip == nil {
                if made.bar.tintColor !== tint { made.bar.tintColor = tint }
            }
        }
    }

    func configureItemColors(_ item: UIBarButtonItem, _ shape: HeaderShape.Item, image: UIImage?) {
        let authored = shape.tint.map { channels in
            UIColor { TextEngine.color(channels[$0.userInterfaceStyle == .dark ? 1 : 0]) }
        }
        let nativeFace = shape.badge == nil && shape.chip == nil
        let capsule: Bool
        if #available(iOS 26.0, tvOS 26.0, *) { capsule = shape.prominent }
        else { capsule = false }
        // older systems draw this as a plain item with inherited platform tint.
        item.tintColor = nativeFace ? (shape.prominent ? (capsule ? presenter.accent.effectiveTint : nil) : authored) : nil
        let font = image == nil ? shape.font : nil
        // title attributes cannot promise a symbol-only prominent foreground.
        let foreground = capsule && image == nil ? authored : nil
        for state: UIControl.State in [.normal, .highlighted, .disabled, .selected, .focused] {
            var attributes: [NSAttributedString.Key: Any] = [:]
            if let font { attributes[.font] = font }
            // disabled ink remains UIKit's; never copy enabled on-fill ink into it.
            if state == .normal, let foreground { attributes[.foregroundColor] = foreground }
            item.setTitleTextAttributes(attributes.isEmpty ? nil : attributes, for: state)
        }
    }
}
#endif
