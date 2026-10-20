# Confetti

**Confetti** fires Raycast's confetti over the display under the pointer: a burst from both bottom
corners that reaches the top, then flutters down and is gone in under three seconds.

## Invariants

- **Click-through and never key.** `ConfettiPanel` is a borderless, non-activating panel that ignores
  the mouse, so nothing under it stops working while it falls.
- **Bursts stack.** Firing again adds a burst to what is still falling on that display, as Raycast's
  does, and never cuts it short; one sheet per display closes once its last burst has fallen.
- **Reduce Motion shows a 🎉 pill instead.**

`ConfettiPanel` adds two `CAEmitterLayer` cannons per burst and removes them once its pieces have
fallen; their speed and gravity scale with the display's height so the burst reaches the top on any
screen. Strips, triangles and dots match Raycast's mix. The paper look relies on undocumented Core
Animation, as Raycast's own does: a `plane` particle type that tumbles each piece through three axes,
and `CAEmitterBehavior` drag and wave, looked up at run time. Where macOS drops them, the confetti
spins flat, or without drag shoots past the top in a quick streak, rather than failing: the launch
speed is tuned for drag to brake it. `ConfettiCoordinator` keeps one panel per
display and closes it when the panel reports its last burst done.

Besides its own `pipcast://command/confetti`, Raycast's `raycast://confetti` and
`raycast://extensions/raycast/raycast/confetti` fire it, from a script or from an extension's
`open(…)`, through `CommandDeepLink.isRaycastConfetti`. Turning Confetti off turns its links off
too: an outside link goes through the command's shortcut funnel, and an extension's checks the same
switch but leaves the palette, and the extension's view in it, open.
