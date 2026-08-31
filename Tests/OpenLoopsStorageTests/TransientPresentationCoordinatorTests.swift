import AppKit
import Testing
@testable import OpenLoops

@MainActor
struct TransientPresentationCoordinatorTests {
    @Test
    func overlappingLeasesSuspendAndRestoreTheExpandedHostExactlyOnce() {
        let host = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        defer { host.close() }
        let coordinator = TransientPresentationCoordinator()
        var expanded = true
        var suspensionCount = 0
        var restorationCount = 0
        coordinator.configure(
            hostWindow: host,
            isHostExpanded: { expanded },
            suspendHost: {
                suspensionCount += 1
                expanded = false
            },
            restoreHost: {
                restorationCount += 1
                expanded = true
            }
        )

        let colour = coordinator.begin("colour", suspendsHost: true)
        let menu = coordinator.begin("menu", suspendsHost: true)
        #expect(suspensionCount == 1)
        #expect(coordinator.activeCount == 2)
        #expect(coordinator.preventsAutoDismiss)

        coordinator.end(colour)
        #expect(restorationCount == 0)
        #expect(coordinator.preventsAutoDismiss)
        coordinator.end(menu)
        #expect(restorationCount == 1)
        #expect(!coordinator.preventsAutoDismiss)
        coordinator.end(menu)
        #expect(restorationCount == 1)
    }

    @Test
    func explicitCancellationPreventsAClosedHostFromRestoringLater() {
        let host = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        defer { host.close() }
        let coordinator = TransientPresentationCoordinator()
        var restorationCount = 0
        coordinator.configure(
            hostWindow: host,
            isHostExpanded: { true },
            suspendHost: {},
            restoreHost: { restorationCount += 1 }
        )

        let popup = coordinator.begin("popup", suspendsHost: true)
        coordinator.cancelAll()
        coordinator.end(popup)

        #expect(coordinator.phase == .idle)
        #expect(!coordinator.preventsAutoDismiss)
        #expect(restorationCount == 0)
    }

    @Test
    func elevatedModalRemainsVisibleWhenSuspensionOrdersOutTheHost() {
        let host = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let modal = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer {
            modal.close()
            host.close()
        }
        host.level = .statusBar
        host.orderFrontRegardless()
        let originalModalLevel = modal.level
        let coordinator = TransientPresentationCoordinator()
        var restorationCount = 0
        coordinator.configure(
            hostWindow: host,
            isHostExpanded: { true },
            suspendHost: { host.orderOut(nil) },
            restoreHost: { restorationCount += 1 }
        )

        coordinator.present(modal, reason: "system-alert")

        #expect(!host.isVisible)
        #expect(modal.isVisible)
        #expect(modal.parent == nil)
        #expect(modal.level.rawValue > host.level.rawValue)
        #expect(coordinator.isTracking(modal))

        coordinator.endScoped(to: modal)
        #expect(restorationCount == 1)
        #expect(modal.level == originalModalLevel)
        #expect(!coordinator.isTracking(modal))
    }

    @Test
    func statusMenuAndEveryNestedSubmenuAreExcludedFromNotchTracking() {
        let coordinator = TransientPresentationCoordinator()
        let statusMenu = NSMenu()
        statusMenu.identifier = TransientPresentationCoordinator.statusMenuIdentifier
        let parentItem = NSMenuItem(title: "Parent", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        parentItem.submenu = submenu
        statusMenu.addItem(parentItem)
        let nestedItem = NSMenuItem(title: "Nested", action: nil, keyEquivalent: "")
        let nestedSubmenu = NSMenu()
        nestedItem.submenu = nestedSubmenu
        submenu.addItem(nestedItem)

        #expect(!coordinator.shouldTrack(statusMenu))
        #expect(!coordinator.shouldTrack(submenu))
        #expect(!coordinator.shouldTrack(nestedSubmenu))
    }

    @Test
    func keyboardOpenedColourPanelUsesTheOriginatingNotchInsteadOfPointerPosition() {
        let host = NSPanel(
            contentRect: NSRect(x: 30_000, y: 30_000, width: 320, height: 180),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let unrelated = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let colour = NSColorPanel()
        let originalColourAccessibilityIdentifier = colour.accessibilityIdentifier()
        defer {
            colour.close()
            unrelated.close()
            host.close()
        }
        host.orderFrontRegardless()

        let coordinator = TransientPresentationCoordinator()
        coordinator.configure(
            hostWindow: host,
            isHostExpanded: { true },
            suspendHost: {},
            restoreHost: {}
        )

        #expect(coordinator.shouldTrack(colour, originatingWindow: host))
        #expect(!coordinator.shouldTrack(colour, originatingWindow: unrelated))

        coordinator.noteKeyResignation(host)
        #expect(coordinator.shouldTrack(colour, originatingWindow: unrelated))
        #expect(!coordinator.shouldTrack(colour, originatingWindow: unrelated))

        coordinator.present(colour, reason: "keyboard-colour-panel")
        #expect(coordinator.preventsAutoDismiss)
        #expect(coordinator.isTracking(colour))
        #expect(colour.identifier == TransientPresentationCoordinator.nativeColorPanelIdentifier)
        #expect(
            colour.accessibilityIdentifier()
                == TransientPresentationCoordinator.nativeColorPanelIdentifier.rawValue
        )
        coordinator.endScoped(to: colour)
        #expect(!coordinator.preventsAutoDismiss)
        #expect(colour.identifier == nil)
        #expect(colour.accessibilityIdentifier() == originalColourAccessibilityIdentifier)
    }
}
