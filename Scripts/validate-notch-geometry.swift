#!/usr/bin/swift

import AppKit
import Foundation

guard let screen = NSScreen.main else {
    fatalError("No main display is available")
}

let panelSize = NSSize(width: 720, height: 350)
let panelFrame = NSRect(
    x: screen.frame.midX - panelSize.width / 2,
    y: screen.frame.maxY - panelSize.height,
    width: panelSize.width,
    height: panelSize.height
)

guard abs(panelFrame.maxY - screen.frame.maxY) < 0.5 else {
    fatalError("Panel is not attached to the physical display top")
}

let notchHotPoint = NSPoint(x: screen.frame.midX, y: screen.frame.maxY - 1)
guard panelFrame.contains(notchHotPoint) else {
    fatalError("The physical notch is outside the panel reveal edge")
}

if #available(macOS 12.0, *),
   let leftSafeArea = screen.auxiliaryTopLeftArea,
   let rightSafeArea = screen.auxiliaryTopRightArea {
    let physicalNotchSize = NSSize(
        width: rightSafeArea.minX - leftSafeArea.maxX,
        height: max(leftSafeArea.height, rightSafeArea.height)
    )

    guard physicalNotchSize.width >= 160, physicalNotchSize.height >= 24 else {
        fatalError("Physical notch metrics are implausible: \(physicalNotchSize)")
    }

    let collapsedShell = NSRect(
        x: panelFrame.midX - physicalNotchSize.width / 2,
        y: panelFrame.maxY - physicalNotchSize.height,
        width: physicalNotchSize.width,
        height: physicalNotchSize.height
    )
    let physicalNotch = NSRect(
        x: leftSafeArea.maxX,
        y: screen.frame.maxY - physicalNotchSize.height,
        width: physicalNotchSize.width,
        height: physicalNotchSize.height
    )

    guard abs(collapsedShell.minX - physicalNotch.minX) <= 0.5,
          abs(collapsedShell.minY - physicalNotch.minY) <= 0.5,
          abs(collapsedShell.width - physicalNotch.width) <= 0.5,
          abs(collapsedShell.height - physicalNotch.height) <= 0.5 else {
        fatalError("Collapsed shell does not align with the physical notch")
    }

    // These rectangles mirror the fixed header regions in NotchBoardView.
    let leftHeaderControls = NSRect(
        x: panelFrame.minX + 20,
        y: panelFrame.maxY - 66,
        width: 188,
        height: 66
    )
    let rightHeaderControls = NSRect(
        x: panelFrame.minX + 472,
        y: panelFrame.maxY - 52,
        width: 232,
        height: 52
    )

    guard leftHeaderControls.maxX <= leftSafeArea.maxX else {
        fatalError("Left header controls overlap the hardware notch")
    }
    guard rightHeaderControls.minX >= rightSafeArea.minX else {
        fatalError("Right header controls overlap the hardware notch")
    }

    print("notch \(physicalNotchSize)")
}

print("Notch geometry validation passed.")
print("screen \(screen.frame)")
print("panel  \(panelFrame)")
