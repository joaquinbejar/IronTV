# Manual regression checklist — macOS floating mini-player

The floating player is AppKit window lifecycle, so it is not unit-testable. Run
this list on macOS before shipping any change to `FloatingPlayerManager`,
`ChannelBrowserView`'s window wiring, or the app's scene/window setup.

Setup: a configured account (or Sample channels), a channel playing in the main
window.

## Every close path must fully exit

For each row: enter the floating player from the toolbar button, then trigger the
close path. Expected in **every** case — the floating window goes away, the
original browser window comes back and takes focus, the toolbar button reads as
"not floating", and entering floating mode again still works.

- [ ] The floating window's own exit button (hover top-left)
- [ ] Double-click the floating window's video area
- [ ] **Cmd-W** while the floating window has focus
- [ ] Close via the Window menu / `performClose(_:)` equivalent
- [ ] The toolbar button again (toggle off)
- [ ] Quit the app (**Cmd-Q**) while floating, then relaunch — the main window must
      come back visible, not ordered out

## Source-window identity

- [ ] Open **Settings** (Cmd-,), leave it open, click back to the browser window,
      enter floating mode. The *browser* window must be the one that hides — not
      Settings, and Settings must stay on screen.
- [ ] With Settings open and focused, enter floating mode from the browser's
      toolbar. Exiting must restore the browser.
- [ ] Close the **browser** window while floating. The floating player must close
      with it and playback must stop, so the provider's connection slot is
      released rather than held by a stream with no owning view. If another window
      remains it comes forward; otherwise the app can be reopened from the Dock.

## Spaces and full screen

- [ ] Enter floating mode, switch to another Space. The floating player follows
      (it joins all Spaces) and stays on top.
- [ ] Enter floating mode, then make another app full screen. The floating player
      stays visible above it.
- [ ] Put the browser window in **full screen**, then enter floating mode, then
      exit. The browser must come back in the state you left it, still usable.
- [ ] Enter full screen *from* the restored browser window afterwards — the
      full-screen toggle must still work.

## Window geometry and playback

- [ ] Resize the floating window from an edge; the 16:9 aspect ratio holds and the
      minimum size is respected.
- [ ] Drag the floating window by its background.
- [ ] Quit and relaunch while floating was used before: the floating window
      reopens at its last saved frame.
- [ ] Video keeps playing across enter/exit, with no black frame left behind — check
      both engines (Playback settings → Apple (HLS) and VLC (MPEG-TS)).
- [ ] Switch channels while floating; playback follows in the floating window.
