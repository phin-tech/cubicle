# Bindings gather their app's new windows

A window that a bound app opens goes to the workspace its app is bound to, even when you opened it on another workspace or display. If you're looking at it, you go with it. Since workspaces replaced Spaces (0002), moving a window is a single instant position write, so the reason in 0001 for never moving windows across Spaces automatically is gone, and "this app lives here" became something Cubicle can keep true.

It only applies to windows Cubicle sees for the first time after it starts. Windows that already exist when Cubicle launches stay where they are, so starting it never rearranges your desktop, and a window you sent elsewhere by hand stays there. A window already on one of its app's bound workspaces stays put. Apps with window bindings are left out, since a window binding picks out single windows that Cubicle can't match reliably the moment a window opens. Ignored apps and paused workspaces are left out too.
