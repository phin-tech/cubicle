# Workspaces replace macOS Spaces

Cubicle no longer switches macOS Spaces. Each display keeps a single Space and gets its own workspaces. Windows on a workspace that isn't showing are parked just off a corner of the display, by writing their position through Accessibility, as AeroSpace and Spaceman do.

On macOS 27 with SIP on, Spaces fight a window manager at every step. The private calls that move another app's window to another Space do nothing, and Accessibility can't see windows on a Space that isn't showing. So moving a window meant a visible trip through other Spaces, about 250 ms through a staging display or 2 s by dragging it. Parking costs one position write per window. Every window stays visible to Accessibility, and sending a window to another workspace is instant. ISS, the switching engine Cubicle forked from InstantSpaceSwitcher, went with Spaces, along with the staging displays and the Mission Control helpers.

The trade-offs:
- Mission Control shows parked windows at the edge of the screen.
- Native full screen still makes a Space of its own.
- Trackpad swipes no longer switch workspaces.
- Some apps move their parked windows back on screen. Cubicle parks them again.
- A crash can leave windows parked, so Cubicle saves where each one belongs and puts it back at the next launch.
- Extra macOS Spaces have to be removed by hand, because Cubicle can't see the windows on them.

To avoid a flash, a switch puts every incoming window back, waits for them all, and only then parks the outgoing ones, as AeroSpace (issue #1305) and Tessel (issue #33) do.

This supersedes [0001](0001-zones-never-pull-windows-across-spaces.md). Its reason for never pulling windows across Spaces automatically, that every move was slow and visible, no longer holds. Whether a binding should now gather its app's windows onto its workspace is an open question.
