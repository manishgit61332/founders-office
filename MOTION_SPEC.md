# Founder's Office Motion System

The notch interaction uses a small physics simulation instead of a fixed-duration fade.

## Reveal

- Trigger: pointer enters the physical notch safe area.
- Spring: stiffness 240, damping 24.
- Initial velocity: 3.4 progress units per second.
- Magnetic pull: up to 18 points toward the pointer entry position, applied only to the early content-free shoulder body. The top neck remains centered on the camera housing, and pull is zero at both endpoints.
- Origin: the collapsed shell uses the connected display's real hardware-notch dimensions. On the current MacBook this is 185 × 32 points.
- Shape timing: the top neck stays attached to the camera housing while curved shoulders widen faster than the panel deepens. The neck catches up only near the settled state, so the transition reads as the notch itself expanding rather than a sheet dropping from the top edge.
- Corner timing: the bottom shoulders round immediately; the panel's 30-point top corners form during the second half of the reveal.
- Content timing: content stays hidden until 66% physics progress and reaches full opacity at 94%, after the expanding-notch silhouette is already clear.
- Overshoot: physics may pass 100%, while the visible shell and true-size content stay within the final 720 × 350 geometry.

## Retraction

- Trigger: pointer remains outside the panel and notch zones for 240 milliseconds.
- Spring: stiffness 340, damping 30.
- Exit velocity: at least -1.8 progress units per second.
- Result: content fades first, the outer body narrows into curved shoulders, and the remaining neck is swallowed by the physical notch.
- Completion: the transparent window leaves the window stack as soon as the surface crosses zero.

## Reversal

If the pointer re-enters during an automatic hover retraction, the spring target reverses without resetting its velocity. The panel therefore feels magnetically caught instead of restarting an animation. Explicit ×, Escape, and menu-bar closes are honored until the shell is fully hidden.

## Accessibility and usability

- Controls accept input only after the panel is at least 90% expanded.
- The NSPanel ignores mouse events before that threshold, so transparent window space never steals clicks from the app underneath.
- The panel stays open while the pointer is inside the visible morph surface or the notch hot zone; hover tracking does not use the fixed transparent 720 × 350 window.
- The menu-bar checklist remains a deterministic fallback and waits for pointer entry instead of immediately auto-dismissing.
- No continuous animation runs while the panel is settled or hidden.
- When macOS Reduce Motion is enabled, reveal and retraction complete without spring interpolation.
