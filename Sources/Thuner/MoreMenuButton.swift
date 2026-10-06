import AppKit
import SwiftUI

/// The ⋯ button in the panel header. A SwiftUI `Menu` becomes the panel's focused control when it opens and
/// draws a blue highlight; a plain NSButton that refuses first responder and pops an NSMenu doesn't.
struct MoreMenuButton: NSViewRepresentable {
    struct Item {
        var title: String
        var symbol: String?
        var isOn: Bool?
        var isEnabled = true
        var action: () -> Void

        static let separator = Item(title: "", action: {})
        var isSeparator: Bool { title.isEmpty }
    }

    var items: [Item]

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "More")!,
                              target: context.coordinator, action: #selector(Coordinator.showMenu(_:)))
        button.isBordered = false
        button.refusesFirstResponder = true
        button.imageScaling = .scaleProportionallyUpOrDown
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        button.contentTintColor = .secondaryLabelColor
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.items = items
    }

    func makeCoordinator() -> Coordinator { Coordinator(items: items) }

    final class Coordinator: NSObject {
        var items: [Item]
        init(items: [Item]) { self.items = items }

        @objc func showMenu(_ sender: NSButton) {
            let menu = NSMenu()
            menu.autoenablesItems = false
            for (index, item) in items.enumerated() {
                if item.isSeparator {
                    menu.addItem(.separator())
                    continue
                }
                let menuItem = NSMenuItem(title: item.title, action: #selector(run(_:)), keyEquivalent: "")
                menuItem.target = self
                menuItem.tag = index
                menuItem.isEnabled = item.isEnabled
                if let symbol = item.symbol { menuItem.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
                if let isOn = item.isOn { menuItem.state = isOn ? .on : .off }
                menu.addItem(menuItem)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
        }

        @objc func run(_ sender: NSMenuItem) {
            items[sender.tag].action()
        }
    }
}
