# Confetti

**Confetti** fires Raycast's confetti over the display under the pointer: a burst from both bottom
corners, falling for a few seconds.

## Invariants

- **Click-through and never key.** `ConfettiPanel` is a borderless, non-activating panel that ignores
  the mouse, so nothing under it stops working while it falls.
- **One burst at a time.** Firing again replaces the sheet rather than stacking another.
- **Reduce Motion shows a 🎉 pill instead.**

`ConfettiPanel` owns the two `CAEmitterLayer` cannons; their speed and gravity scale with the display's
height so the burst reaches most of the way up on any screen. `ConfettiCoordinator` stops the cannons
after a fraction of a second and closes the sheet once the last piece has fallen.
