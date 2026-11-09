# Moving windows between Spaces

## Current verified result

On macOS 27 with SIP enabled, virtual-display staging successfully moved the tested Terminal window
between native Spaces, restored its original geometry, and returned the user to their starting Space.
`cubicle send --via-virtual --stay <target>` uses a 1280×720, 60 Hz non-HiDPI staging display. It briefly
visits the destination, so a flash remains. Displays must have separate Spaces enabled.

The prototype creates the display on demand and removes it after 10 seconds idle if tracked windows
are clear of it. Subsequent moves reuse it and restart the timer. Idle cleanup and recreation were
verified with successive display IDs 19 and 20. Readiness checks replace fixed delays.

## Implemented settings

Users may move several windows in succession. Provide these persisted settings:

- **Automatically turn off staging display when idle:** toggle, enabled by default.
- **Turn off after:** adjustable duration in seconds, default **10 seconds**. Disable the duration
  control when automatic shutdown is off. The accepted range is 1–3600 seconds.
- When automatic shutdown is off, create the display on first use and retain it until manual removal
  or app exit. Do not create it eagerly at launch.
- Reset the idle countdown after each completed move. Cancel it while a move is running. Never remove
  staging while tracked windows remain there or their location cannot be verified.
- Keep the menu's manual off control when no move is running; the next move recreates the display.
- Disabling automatic shutdown cancels a pending countdown. Enabling it or changing the duration
  starts a fresh countdown when idle; changes during a move apply after completion.

This supports repeated sequential moves without paying startup cost for each window. Batch commands
and simultaneous moves are not part of this settings decision.

## Observed performance

Single-machine observations, not benchmark averages:

| Scenario | Display startup | Move and return | Combined |
|---|---:|---:|---:|
| Already running | None | 233 ms | 233 ms |
| Cold start | 439 ms | 353 ms | 792 ms |
| Cold start after idle cleanup | 417 ms | 256 ms | 673 ms |

A 1920×1080 off/on RSS comparison showed approximately 13.7 MiB additional combined resident memory:
Cubicle 97.4 → 98.3 MiB, WindowServer 168.8 → 181.5 MiB (difference computed before rounding).
A later 1280×720 enabled snapshot was Cubicle 111.7 MiB and WindowServer 156.5 MiB, combined 268.1 MiB.
There is no matched smaller-display off/on comparison yet. These readings include normal process
fluctuations and do not capture all GPU allocations; they are not precise display memory costs.

## Remaining work

Measure repeated cold/warm moves and matched memory samples; test
other apps' minimum window sizes, display layouts, closed windows, and recovery paths. Current idle
cleanup checks tracked windows only: unrelated windows placed on staging are not protected by that
check. Connection prompts and display-layout effects need broader testing.

## Historical spike notes

Earlier dimensions, delays, and unverified-result notes below record the progression of experiments;
the verified result above supersedes them.

Notes from a spike on 2026-11-08: can Cubicle move another app's window to a different Space, with SIP on, on
macOS 27? Short answer: not through any private API or the minimize trick we found. Holding the window's title bar while the system
switches Spaces does work, but it's visible.

The spike is the `cubicle send <name|number>` command, which moves the focused window with technique 5 below. Code:
`Sources/InstantSpaceSwitcher/Core/WindowMover.swift`, `WindowSender.swift`, and the private calls in
`WindowServer.swift` and `VirtualDisplay.swift` (Cubicle keeps its own private calls in Swift so `Sources/ISS` stays
identical to upstream). Each attempt checks the window's Space afterwards with `CGSCopySpacesForWindows`, because the
blocked calls return without error. The direct `CGSMoveWindowsToManagedSpace` and compat-ID attempts were removed
once they proved blocked on macOS 27.

## What we tried

| # | Technique | Result on macOS 27, SIP on |
|---|-----------|---------------------------|
| 1 | `CGSMoveWindowsToManagedSpace(cid, [wid], space)` | Ignored. Window stays on its Space. |
| 2 | yabai's no-SIP workaround: `SLSSpaceSetCompatID(cid, space, tag)`, then `SLSSetWindowListWorkspace(cid, &wid, 1, tag)`, then clear the tag | Ignored. |
| 3 | `SLSBridgedMoveWindowsToManagedSpaceOperation` (`initWithWindows:spaceID:`, then `performWithWMBridgeDelegate` or `invokeFallback`), the idea from [rift #404](https://github.com/acsandmann/rift/issues/404) | Ignored for another process's window. **Works on the calling process's own window** (Space 459 to 1), so the call itself is right and macOS refuses it for other apps. |
| 4 | Synthetic mouse-down on the title bar, then Cubicle's instant switch (synthetic Dock swipe), then mouse-up | The Space never changes: the Dock ignores the synthetic swipe while a mouse button is held. |
| 5 | Synthetic mouse-down on the title bar, then the system "Move right/left a space" shortcut (Ctrl+arrow, posted with the control, fn and numeric-pad flags), then mouse-up | **Works.** The window comes along. |
| 6 | Minimize the window through Accessibility, switch with Cubicle's instant swipe, then restore it | Fails. The minimize and the switch both work, but macOS remembers the window's Space: restoring puts it back there and switches you back to it. |

Test 3 used a throwaway helper process that owned a small window, so no real window was moved. A separate probe
process tried to move it; for the control, the helper moved its own window.

### What it takes to make #5 reliable

- Long holds. With a 0.1 s hold and 0.35 s before letting go it failed. With 0.5 s before the first keypress,
  0.8 s per extra step and 1.2 s before mouse-up it works. These match the timings Keyboard Maestro's "Desktop Spaces"
  macros ended up with ([KM forum](https://forum.keyboardmaestro.com/t/macros-desktop-spaces-macros-to-improve-navigation-and-window-management-v4-0/27033)).
- You go to the target Space along with the window, with the system's slide animation. The cursor visibly jumps to the
  title bar and back.
- It needs a grabbable spot on the title bar. The spike grabs the middle, which may hit a tab in Chrome or Safari.
- Full-screen windows can't be moved this way. Spaces on another display are untested.
- The CLI waits up to 15 s for `send`, because each step animates.

## What others found

- A test on macOS 26.7.1 with SIP on found `CGSMoveWindowsToManagedSpace` and `CGSAddWindowsToSpaces` /
  `CGSRemoveWindowsFromSpaces` have no effect on other processes' windows but work on the process's own windows. Same
  pattern as #3 ([minsfb/spaces #6](https://github.com/minsfb/spaces/issues/6)).
- ShiftPlus, a commercial Spaces app, reports the SkyLight move calls and the compat-ID trick fail silently on macOS 15
  and 26. It avoids moving windows at all: it switches the Space and relaunches the app there
  ([ShiftPlus](https://shiftplus.app/blog/macos-spaces-without-disabling-sip/)).
- yabai's window-to-Space moves broke for users starting with macOS 15. yabai's full features need its scripting
  addition, which is injected into the Dock and needs SIP partly off
  ([yabai #2380](https://github.com/koekeishiya/yabai/issues/2380), [#2469](https://github.com/asmvik/yabai/issues/2469)).
- Amethyst still ships "throw window to Space" on Sonoma and Sequoia, but its maintainer says that under the new
  restrictions "there is no way to not follow the window" ([Amethyst #1713](https://github.com/ianyh/Amethyst/issues/1713)).
  That matches #5.
- AeroSpace skips native Spaces entirely. It runs its own workspaces and parks hidden windows off-screen
  ([AeroSpace](https://github.com/nikitabobko/AeroSpace)). That's instant and needs no SIP changes, but gives up the
  named native Spaces that Cubicle is built around.
- Scopo lists a "Move window" Pro feature, but its site doesn't say whether it moves windows between Spaces
  ([scopo.app](https://scopo.app)).

## Other limits

- Accessibility can't see windows on Spaces other than the current one (`kAXWindowsAttribute` returns nothing for
  them), so a window list or tiling can only cover the current Space.
- Moving a window to another display with Accessibility (`kAXPositionAttribute`) works, but the window joins whatever
  Space that display is showing.

## Not tried yet

- **The Dock's "Assign To" menu:** set the app to "All Desktops", switch instantly to the target, then set it back to
  "None" so its windows stay there. That moves every window of the app, not just one, works only for apps in the Dock,
  and means opening the Dock's menu through Accessibility.
- **"Switch to Desktop N" shortcuts:** one hop instead of a Ctrl+arrow step per Space. They're off by default; Cubicle
  could turn them on (`com.apple.symbolichotkeys`, keys 118 and up).
- Hiding the cursor during the drag.
- Turning on Reduce Motion (a user setting) turns the slide into a quick fade.

## Quick-drag probe

`cubicle send --quick-drag <name|number>` holds the title bar for 0.5 s, posts Cubicle's instant switch,
then releases after another 1.2 s. It reports whether the switch was posted, the active Space while held
and before release, and the final window Space. This revisits attempt #4 with the longer drag hold;
it is not yet a demonstrated workaround. Normal `send` still uses Ctrl+arrow.

Another untested idea is a spare (physical or virtual) display as a staging area: move the window there
with Accessibility, switch the original display to the destination, then move the window back. Verify
that the same window joins the destination Space before returning to the starting Space. A physical
second display can test the premise before implementing private CGVirtualDisplay support.

Quick-drag observation: the user reports that it switches Spaces but leaves the window behind.

`cubicle send --via-display <name|number>` probes the staging idea using an existing second monitor.
It requires separate Spaces and a window small enough to fit entirely on the staging display. It checks
parking before switching, returns the window to its original coordinates, and reports its final Space.
It follows the window to the destination for now. Runtime success is still unverified.

Physical-display staging succeeded in the user's test. The virtual version is available as
`cubicle send --via-virtual <name|number>` (runtime result pending). It creates a 4096×4096 non-HiDPI
"Cubicle Staging (Experimental)" display using private CGVirtualDisplay APIs, waits for registration,
then explicitly selects that display for staging. It stays alive until Cubicle exits. The probe does
not hide the monitor from System Settings or prevent the cursor/other windows from entering it.
Quit Cubicle to remove it; do not intentionally leave other windows there. Separate Spaces is required.
API signature reference: https://github.com/Stengo/DeskPad/blob/main/DeskPad/CGVirtualDisplayPrivate.h

Staging now temporarily shrinks oversized windows to fit the destination display, saves the original
frame, and restores position and size on return (including parking failure). It verifies the returned
frame within two points and reports geometry restoration separately from Space membership. Missing
extended displays now produce a separate error from size failures. Apps can reject resizing or impose
minimum sizes; the parking check catches windows that still do not fit.

The first virtual-display test returned an ID but never appeared in NSScreen or System Settings.
The revised probe uses a standard 1920×1080 mode and the reference's setDispatchQueue selector;
this is an experiment, not a confirmed fix. The menu now provides an Experimental Virtual Display
toggle: Off means no owned display, Ready means its ID appears in NSScreen, and Unavailable means
an object exists but no corresponding screen is exposed. Toggle off to release it, then on to retry.
This supersedes the initial 4096×4096 mode described above. Window resizing handles staging fit.

Virtual staging succeeded in the user's runtime test: window 13968 moved from Space 459 through
virtual Space 680 to Space 1. All AX restore calls returned success, but the final geometry differed
by more than two points, so the original combined success check falsely reported a failed move.
Move success now depends on final Space membership; geometry differences produce a separate warning
with expected and actual frames. Exact geometry restoration remains unresolved.

`send --via-virtual --stay <target>` (also `--via-display --stay`) now returns to the starting
Space after verifying the move, and rechecks the window's membership afterward. This still visits
the destination briefly; it is not an invisible background move. Size restoration now waits 0.5 s
after the cross-display return before expanding the window, then waits 0.4 s before verification.
This targets the observed height clamp (1655 requested, 1049 restored on a 1080-high staging display).
The revised resize timing and --stay behavior require runtime verification.

Speed probe: fixed waits (including the unconditional 1.5 s virtual-display wait) are replaced by
10 ms nonblocking readiness checks. Parking requires both staging bounds and changed Space membership;
return requires original-display bounds and destination membership. Geometry restoration retries at
50 ms intervals to handle app-side display-constraint lag. Each transition has a 1.5 s deadline;
virtual-display registration allows 3 s and skips waiting when already visible. CLI reports cumulative
milliseconds for parking, destination switch, window return, geometry restoration, and total. Runtime
latency and reliability still need measurement; active Space readiness does not prove visual settling.

The staging display default is now 1280×720 at 60 Hz, non-HiDPI, to reduce pixel-buffer costs.
The existing margins leave 1200×620 for a temporarily resized window. Apps with larger minimum
sizes may fail the parking check. Restart Cubicle to recreate the display at the new size;
RAM savings and runtime behavior at this resolution remain to be measured.

On-demand lifecycle probe: virtual sends create/reuse the display and schedule removal 10 seconds
after completion. A subsequent virtual move cancels/restarts that timer. Concurrent virtual sends
are rejected, and the menu cannot remove the display during one. Removal checks the tracked windows'
current frames: if any intersects staging or cannot be read, the display stays attached for recovery.
The menu toggle remains a manual override when no move is running. CLI now reports display-readiness
latency separately from move timing. Cold-start prompts and idle removal need runtime verification.

Settings → General → Window Moves now provides the persisted automatic-shutdown toggle and timeout.
The default remains enabled with a 10-second idle interval. CLI lifecycle diagnostics reflect these preferences.
