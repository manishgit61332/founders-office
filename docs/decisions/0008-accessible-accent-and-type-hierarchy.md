# ADR 0008: Accessible accent fills and a three-role type hierarchy

- Status: Accepted
- Date: 2026-08-31

## Context

Founder’s Office lets a customer choose any 8-bit RGB accent. A fixed white button label becomes unreadable on bright colours such as `#7EFABE`. The Mac notch, onboarding, and iPhone companion also accumulated one-off font sizes that weakened scanning and made the visual hierarchy unpredictable.

## Decision

For every opaque text-bearing accent fill, calculate sRGB relative luminance and the WCAG contrast ratio, then use whichever of opaque black or white produces the higher ratio. Text-bearing accent fills remain opaque so the calculation describes the pixels that are rendered. Gradients are decorative; text must sit on the solid primary stop with its calculated foreground or on a separate opaque backing.

Use exactly three semantic text roles in app-owned UI:

1. Primary title: 28 points, normally the display face.
2. Secondary: primary divided by 1.62, normally the interface face.
3. Tertiary: secondary divided by 1.6, used only for supporting information.

SF Symbol optical sizes and Apple-owned navigation or system-control typography are independent of the text scale. Weight, spacing, shape, semantic colour, and placement carry hierarchy without introducing more text sizes.

## Consequences

Arbitrary bright and dark accents remain usable on Mac and iPhone. A screen has one clear title, actionable objects read at the secondary level, and metadata cannot drift into a collection of tiny grey sizes. Long Move titles may truncate sooner in the fixed notch width and must keep their full accessibility label and edit surface.

## Privacy and security

All calculations are deterministic and local. No colour, font, task, identity, or usage data leaves the device.

## Migration and rollback

No persisted schema changes. Existing appearance files render through the new contrast and typography rules immediately. Reverting only changes presentation.

## Related work

- `Sources/FounderOfficeCore/AppearanceModels.swift`
- `Sources/OpenLoops/FounderTheme.swift`
- `Sources/OpenLoops/NotchBoardView.swift`
- `Apps/iOS/Theme.swift`

