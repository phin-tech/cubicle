# Zones only arrange windows already on the Space

_Superseded by [0002](0002-workspaces-replace-macos-spaces.md): Cubicle replaced macOS Spaces with its own workspaces, so moving a window between them is instant._

A Space's layout only places windows that are already on that Space. Cubicle never pulls a bound app's windows onto it from another Space on its own, for example when you switch Spaces or a window opens elsewhere; if a bound app has no window on a Space, it simply isn't shown there. Moving windows between Spaces is something you ask for: `cubicle send`, the send menu, and (later) applying a saved arrangement on request.

On macOS 27 with SIP on, the private APIs for moving another app's window between Spaces silently do nothing, and Accessibility cannot see windows on other Spaces. The method that works best is staging through another display (a real second monitor, or Cubicle's virtual one): park the window there, switch the Space, bring it back (see `docs/moving-windows-between-spaces.md`). It takes about 250 ms per window (most of a second from cold), shows a brief flash of the destination Space, and needs "Displays have separate Spaces". The title-bar drag with Ctrl+arrow is the fallback and takes about 2 s. Either way, every move costs a visible trip through other Spaces, and finding a window on another Space means visiting it first. Doing that automatically would turn Cubicle's instant switch into a flicker the user never asked for, so cross-Space moves only happen when the user asks for one.

_Revised 2026-11-11: the original reasoning cited only the 2 s drag. Display staging made moves fast enough for on-request use, but not invisible, so the rule against automatic pulling stands._
