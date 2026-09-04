import AppKit
import Testing
@testable import OpenLoops

@MainActor
struct NotchSpaceVisibilityTests {
    @Test("The notch is a nonactivating overlay that joins desktops and other apps")
    func overlayWindowPolicy() {
        let panel = NotchPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 350),
            styleMask: NotchPanel.notchStyleMask,
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        panel.collectionBehavior = NotchPanel.notchCollectionBehavior
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.canJoinAllApplications))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(!panel.collectionBehavior.contains(.moveToActiveSpace))
        #expect(!panel.collectionBehavior.contains(.primary))
        #expect(!panel.collectionBehavior.contains(.auxiliary))
    }

    @Test("A Space transition restores only an expanded, unobstructed notch", arguments: [
        NotchPanelState.open, .opening
    ])
    func expandedNotchIsReordered(state: NotchPanelState) {
        #expect(NotchSpaceChangeAction.resolve(state: state, hasTransient: false) == .reorderExpanded)
        #expect(NotchSpaceChangeAction.resolve(state: state, hasTransient: true) == .deferToTransient)
    }

    @Test("A Space change cannot reopen an explicitly closed notch", arguments: [
        NotchPanelState.hidden, .closing
    ])
    func hiddenNotchStillRequiresHover(state: NotchPanelState) {
        #expect(NotchSpaceChangeAction.resolve(state: state, hasTransient: false) == .checkHover)
        #expect(NotchSpaceChangeAction.resolve(state: state, hasTransient: true) == .checkHover)
    }

    @Test("A suspended native popup retains ownership after a Space change")
    func suspendedPopupIsNotCovered() {
        #expect(NotchSpaceChangeAction.resolve(state: .suspended, hasTransient: true) == .deferToTransient)
        #expect(NotchSpaceChangeAction.resolve(state: .suspended, hasTransient: false) == .deferToTransient)
    }
}
