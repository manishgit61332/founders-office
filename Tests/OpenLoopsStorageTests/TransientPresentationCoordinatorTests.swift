import AppKit
import FounderOfficeCore
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
    func nativeOpenPanelRegistersBeforeBeginWhileSuspendedHostStaysOut() {
        let host = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let modal = NSOpenPanel()
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

        coordinator.present(
            modal,
            request: TransientPresentationRequest(
                kind: .fileChooser,
                hostDisposition: .suspendExpandedHost
            )
        )

        #expect(!host.isVisible)
        #expect(!modal.isVisible)
        #expect(coordinator.activeCount == 1)
        #expect(modal.identifier == TransientPresentationCoordinator.nativeOpenPanelIdentifier)

        // Simulate AppKit entering the panel's running phase. The host is gone,
        // so the chooser keeps native modal ordering instead of becoming a
        // globally floating status-bar window.
        modal.level = .modalPanel
        modal.orderFrontRegardless()
        coordinator.promoteIfVisible(modal)

        #expect(modal.isVisible)
        #expect(modal.parent == nil)
        #expect(modal.level == .modalPanel)
        #expect(!modal.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(coordinator.isTracking(modal))

        // A later AppKit callback remains idempotent without acquiring a
        // duplicate lease or changing the native level.
        modal.level = .modalPanel
        coordinator.promoteIfVisible(modal)
        #expect(modal.level == .modalPanel)
        #expect(coordinator.activeCount == 1)

        coordinator.dismissAndEnd(modal)
        #expect(restorationCount == 1)
        #expect(modal.level == originalModalLevel)
        #expect(modal.identifier == nil)
        #expect(!coordinator.isTracking(modal))
    }

    @Test
    func retainedHostPopoverWindowIsPromotedWithoutReparenting() {
        let host = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let popoverWindow = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        defer {
            popoverWindow.close()
            host.close()
        }
        host.level = .statusBar
        host.orderFrontRegardless()
        popoverWindow.orderFrontRegardless()
        let originalLevel = popoverWindow.level
        let owner = NSObject()
        let coordinator = TransientPresentationCoordinator()
        coordinator.configure(
            hostWindow: host,
            isHostExpanded: { true },
            suspendHost: {},
            restoreHost: {}
        )
        _ = coordinator.present(
            request: TransientPresentationRequest(
                kind: .popover,
                hostDisposition: .retainExpandedHost
            ),
            scopedTo: owner
        )

        coordinator.elevate(popoverWindow, scopedTo: owner)
        #expect(host.isVisible)
        #expect(popoverWindow.level.rawValue > host.level.rawValue)
        #expect(popoverWindow.parent == nil)

        coordinator.endScoped(to: owner)
        #expect(popoverWindow.level == originalLevel)
    }

    @Test
    func overlappingNativePanelsRestoreOnlyAfterTheFinalPanelCloses() {
        let host = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let openPanel = NSOpenPanel()
        let savePanel = NSSavePanel()
        defer {
            openPanel.close()
            savePanel.close()
            host.close()
        }
        host.level = .statusBar
        host.orderFrontRegardless()

        let coordinator = TransientPresentationCoordinator()
        var restorationCount = 0
        coordinator.configure(
            hostWindow: host,
            isHostExpanded: { host.isVisible },
            suspendHost: { host.orderOut(nil) },
            restoreHost: {
                restorationCount += 1
                host.orderFrontRegardless()
            }
        )

        coordinator.present(
            openPanel,
            request: TransientPresentationRequest(
                kind: .fileChooser,
                hostDisposition: .suspendExpandedHost
            )
        )
        coordinator.present(
            savePanel,
            request: TransientPresentationRequest(
                kind: .fileChooser,
                hostDisposition: .suspendExpandedHost
            )
        )
        #expect(coordinator.activeCount == 2)
        #expect(savePanel.identifier == TransientPresentationCoordinator.nativeSavePanelIdentifier)

        openPanel.orderFrontRegardless()
        savePanel.orderFrontRegardless()
        coordinator.promoteIfVisible(openPanel)
        coordinator.promoteIfVisible(savePanel)
        coordinator.dismissAndEnd(openPanel)
        #expect(restorationCount == 0)
        #expect(!host.isVisible)

        coordinator.dismissAndEnd(savePanel)
        #expect(restorationCount == 1)
        #expect(host.isVisible)
        #expect(coordinator.activeCount == 0)
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

        coordinator.present(
            colour,
            request: TransientPresentationRequest(
                kind: .colorPanel,
                hostDisposition: .suspendExpandedHost
            )
        )
        #expect(coordinator.preventsAutoDismiss)
        #expect(coordinator.isTracking(colour))
        #expect(colour.identifier == TransientPresentationCoordinator.nativeColorPanelIdentifier)
        #expect(
            colour.accessibilityIdentifier()
                == TransientPresentationCoordinator.nativeColorPanelIdentifier.rawValue
        )
        colour.orderFrontRegardless()
        #expect(coordinator.closeNativeColorPanels())
        #expect(!colour.isVisible)
        #expect(!coordinator.preventsAutoDismiss)
        #expect(colour.identifier == nil)
        #expect(colour.accessibilityIdentifier() == originalColourAccessibilityIdentifier)
    }

    @Test
    func portableRequestsPreserveDispositionAndScopedLeaseOwnership() {
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

        let retained = coordinator.present(
            request: TransientPresentationRequest(
                kind: .inNotchEditor,
                hostDisposition: .retainExpandedHost
            )
        )
        let owner = NSObject()
        let firstScoped = coordinator.present(
            request: TransientPresentationRequest(
                kind: .datePicker,
                hostDisposition: .suspendExpandedHost
            ),
            scopedTo: owner
        )
        let duplicateScoped = coordinator.present(
            request: TransientPresentationRequest(
                kind: .datePicker,
                hostDisposition: .suspendExpandedHost
            ),
            scopedTo: owner
        )

        #expect(firstScoped == duplicateScoped)
        #expect(coordinator.activeCount == 2)
        #expect(suspensionCount == 1)

        coordinator.endScoped(to: owner)
        #expect(restorationCount == 0)
        coordinator.end(retained)
        #expect(restorationCount == 1)
        #expect(!coordinator.preventsAutoDismiss)
    }
}
