# Cubicle

Instant, named, searchable Spaces for macOS, growing into light window management.

## Language

### Window management

**Snap**:
Moving and resizing one window to a preset region of the display it is on, in a single command. Snapping to a region that has a **Zone** puts the window in that zone (and its **Stack**'s cycle) until it is moved by hand or closes; "snap" and "send to zone" are the same command. Snapping never creates or changes a **Binding**.
_Avoid_: tile, arrange

**Maximize**:
The snap that fills the display's usable area (the screen minus the menu bar and Dock). The window stays on its current Space.
_Avoid_: full screen (that is macOS's native full screen, which gives the window its own Space; Cubicle does not do this)

**Center**:
The snap that keeps a window's size and moves it to the middle of its display. It has no **Zone**.

**Restore**:
The snap that puts a window back to the frame it had before Cubicle first snapped it. Moving a window by hand and snapping it again records a new frame to restore to. Restore (and **Center**) also lets go of the window: it leaves its **Zone** and becomes a **Floating window**. A bound window Cubicle placed automatically restores to the frame it opened with.

**Gap**:
One user setting, in pixels, kept between snapped windows and between a window and the display edge. Shared by snaps and **Zones**.

**Zone**:
A named rectangle that windows can be placed in, defined as a fraction of the display's usable area (so it follows the display if it changes size). Every Space has the same fixed set of zones (the halves, the quarters, and "full", which is the **Maximize** rectangle), and they cover exactly the same rectangles as the matching **Snap** commands. Center and Restore have no zone. Zones overlap. A zone is "occupied" on a Space when windows are in it there.
_Avoid_: slot, region, tile

**Layout**:
The set of **Bindings** saved for one Space. A Space with no bindings has an empty layout; its zones still exist and windows can still be sent to them.

**Stack**:
The windows in one **Zone** on one Space, in a fixed cycle order: the windows of the apps bound to it (in binding order, then each app's windows in the order they opened), followed by any windows snapped into it. Every window of a bound app belongs in that zone, including windows opened later and after the app relaunches, unless it is a **Pulled-out window**. A stack is cycled window by window, not app by app.
_Avoid_: group, set

**Floating window**:
A window that is not in any **Zone**: it was never snapped and its app has no **Binding** on that Space, or the user moved or resized it by hand (including macOS's own tiling).

**Pulled-out window**:
A window of a bound app that the user took out of its **Stack**, by moving or resizing it by hand (it becomes a **Floating window**) or by snapping it to another zone (it joins that zone's stack until it closes or is moved by hand, without changing any **Binding**).

**Binding**:
The saved link between an app and a **Stack** on a particular Space. An app has at most one binding per Space; binding it again moves it to the new zone. The same app may be bound on several Spaces.

**Ignored app**:
An app on the user's single, global ignore list. It cannot be bound, its windows never join a **Zone**, and automatic placement leaves it alone; its windows can still be snapped on request (frame only). Sheets, dialogs, fixed-size panels and native full-screen windows are always treated this way without being listed.

**Paused stacking**:
A Space whose **Layout** is kept but ignored: nothing is placed automatically, snaps only set the window's frame, and cycling and swapping do nothing. When stacking resumes, the layout is applied straight away. A global pause stops stacking on every Space without changing each Space's own setting.

## Flagged ambiguities

- "Full screen" was used to mean **Maximize**. Resolved: Cubicle never enters native full screen.
