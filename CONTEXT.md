# Cubicle

Instant, named, searchable workspaces for macOS, growing into light window management.

## Language

### Workspaces

**Workspace**:
One of a display's own desktops, each with its own windows; every display has the same number of them, and one is showing at a time. Cubicle's workspaces replace macOS Spaces: macOS keeps a single Space per display.
_Avoid_: Space, desktop (those are macOS's own; "Space" survives in older code and settings names)

**Parked window**:
A window whose **Workspace** isn't showing, held just off a corner of its display until its workspace is shown again.
_Avoid_: hidden window (macOS's Hide is a different thing), minimized

**Send**:
Moving a window to another **Workspace** on its display. It is instant, and a window sent to a workspace that isn't showing is parked at once.
_Avoid_: move to Space, send to zone (putting a window in a **Zone** is a **Snap**)

### Window management

**Snap**:
Moving and resizing one window to a preset region of the display it is on, in a single command. Snapping to a region that has a **Zone** puts the window in that zone (and its **Stack**'s cycle) until it is moved by hand or closes. Snapping never creates or changes a **Binding**.
_Avoid_: tile, arrange

**Maximize**:
The snap that fills the display's usable area (the screen minus the menu bar and Dock). The window stays on its current **Workspace**.
_Avoid_: full screen (that is macOS's native full screen, which gives the window its own macOS Space; Cubicle does not do this)

**Center**:
The snap that keeps a window's size and moves it to the middle of its display. It has no **Zone**.

**Restore**:
The snap that puts a window back to the frame it had before Cubicle first snapped it. Moving a window by hand and snapping it again records a new frame to restore to. Restore (and **Center**) also lets go of the window: it leaves its **Zone** and becomes a **Floating window**. A bound window Cubicle placed automatically restores to the frame it opened with.

**Gap**:
One user setting, in pixels, kept between snapped windows and between a window and the display edge. Shared by snaps and **Zones**.

**Zone**:
A named rectangle that windows can be placed in, defined as a fraction of the display's usable area (so it follows the display if it changes size). Every workspace has the same fixed set of zones (the halves, the quarters, and "full", which is the **Maximize** rectangle), and they cover exactly the same rectangles as the matching **Snap** commands. Center and Restore have no zone. Zones overlap. A zone is "occupied" on a workspace when windows are in it there.
_Avoid_: slot, region, tile

**Layout**:
The set of **Bindings** saved for one workspace. A workspace with no bindings has an empty layout; its zones still exist and windows can still be snapped into them.

**Stack**:
The windows in one **Zone** on one workspace, in a fixed cycle order: the windows of the apps bound to it (in binding order, then each app's windows in the order they opened), followed by any windows snapped into it. Every window of a bound app belongs in that zone, including windows opened later and after the app relaunches, unless it is a **Pulled-out window**. A stack is cycled window by window, not app by app.
_Avoid_: group, set

**Cycle**:
Bringing the next or previous window in the focused window's **Stack** to the front and focusing it, wrapping around at the ends. It changes no order and moves no window.

**Swap**:
Trading the whole **Stacks** of two **Zones** on one workspace, usually neighbours (the left and right halves, or two quarters side by side): every window moves to the other zone and keeps its cycle order. Like a **Snap**, a swap changes no **Binding**: a bound window that lands outside its own zone is held there until it closes or is moved by hand, and one that lands in its own zone is simply home.

**Floating window**:
A window that is not in any **Zone**: it was never snapped and its app has no **Binding** on that workspace, or the user moved or resized it by hand (including macOS's own tiling).

**Pulled-out window**:
A window of a bound app that the user took out of its **Stack**, by moving or resizing it by hand (it becomes a **Floating window**) or by snapping it to another zone (it joins that zone's stack until it closes or is moved by hand, without changing any **Binding**).

**Binding**:
A saved rule that places an app's windows, or one particular window, on a particular workspace, optionally in a **Zone** (joining its **Stack**). A new window of a bound app goes to its workspace, wherever it opened. An app has at most one app binding per workspace; binding it again moves it to the new zone. The same app may be bound on several workspaces. A window binding wins over its app's binding. A window binding recognises its window again after the app restarts by the window's document, else its title, else its place in the app's window order.
_Avoid_: home, assignment, pin

**Ignored app**:
An app on the user's single, global ignore list. It cannot be bound, its windows never join a **Zone**, and automatic placement leaves it alone; its windows can still be snapped on request (frame only). Sheets, dialogs, fixed-size panels and native full-screen windows are always treated this way without being listed.

**Paused stacking**:
A workspace whose **Layout** is kept but ignored: nothing is placed automatically, snaps only set the window's frame, and cycling and swapping do nothing. When stacking resumes, the layout is applied straight away. A global pause stops stacking on every workspace without changing each workspace's own setting.

## Flagged ambiguities

- "Full screen" was used to mean **Maximize**. Resolved: Cubicle never enters native full screen.
- "Space" meant a macOS Space until Cubicle replaced them with **Workspaces**. Resolved: say workspace; the code's `Space*` type names still mean workspaces.
