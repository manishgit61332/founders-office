# ADR 0006: Composable, versioned appearance personalization

- Status: Accepted
- Date: 2026-08-31

## Context

Founder’s Office needs recognizable starting styles without trapping people in a handful of presets. Appearance also has to survive local persistence and iCloud sync across the Mac notch app and iPhone companion without breaking older personalization files.

## Decision

Store appearance as an optional schema-version-6 payload with independent axes for accent, display font, interface font, move-card style, and surface material. Presets seed those axes; changing any one axis marks the result as Custom without resetting the others.

Accents use exact 8-bit red, green, and blue channels. They may be solid or use ordered gradient stops plus an angle. Identifiers are string-backed so an unknown future theme or font identifier survives decode-and-encode on another schema-version-6-capable client.

The initial built-in directions are Manish, Native, Soft AI, and Pixel. Product-facing style names describe the visual direction without shipping third-party trademarks as theme names. Font choices are bundled or system-provided so themes remain licensable and deterministic across devices. Arbitrary uploaded font files are out of scope.

macOS transient editors—date popovers, menus, colour panels, and file choosers—hold an interaction lease while active. Automatic notch dismissal resumes only after all leases end. Reduced Transparency forces an opaque fallback regardless of the selected material.

## Consequences

People can mix typography, card geometry, surface material, and exact colours independently. The legacy five-colour field remains dual-written for older clients. Whole-personalization last-writer-wins sync remains the current merge policy; field-level appearance merging is future work. A pre-version-6 client can drop the optional appearance payload on its next write, so the paid-beta rollout must update Mac and iOS together or enforce a minimum compatible version before mixed-version iCloud sync is supported.

## Privacy and security

Appearance data contains no credentials. Vision images keep their existing private local/iCloud handling. The app does not download or execute third-party font files.

## Migration and rollback

Older personalization documents decode with no appearance payload and resolve to the Manish style using their saved legacy accent. Removing the optional appearance payload rolls a profile back without changing identity, goals, calendars, or images.

## Related work

- `Sources/FounderOfficeCore/AppearanceModels.swift`
- `Sources/FounderOfficeCore/InteractionLeaseRegistry.swift`
- `Sources/OpenLoops/FounderTheme.swift`
- `Sources/OpenLoops/NotchWindowController.swift`
