# overnits

Push a MacBook Pro XDR display past its SDR brightness ceiling, using only
public macOS APIs. Roughly 250 lines of Swift, no dependencies.

The built-in display of a 14"/16" MacBook Pro reaches 1000 nits sustained and
1600 nits peak, but macOS caps ordinary (SDR) content at 500 or 600 nits
depending on the model. `overnits` unlocks the rest for normal desktop use.

## Requirements

- Apple Silicon MacBook Pro 14"/16", or a Pro Display XDR
- macOS 12 or later

It does nothing useful on a MacBook Air, an iMac, or a Studio Display: those
panels have no headroom above their SDR maximum.

## Install

```sh
brew install kanapitsas/tap/overnits
brew services start overnits      # optional: start at login
```

Or build it yourself:

```sh
git clone https://github.com/kanapitsas/overnits.git
cd overnits && make && sudo make install
```

## Use

Run `overnits`. A sun icon appears in the menu bar with the available factors.

| Shortcut | Action |
| --- | --- |
| `Cmd` `Option` `B` | toggle on/off |
| `Cmd` `Option` `=` | brighter |
| `Cmd` `Option` `-` | dimmer |

Command line flags: `--boost <factor>`, `--seconds <n>` to quit automatically,
`--log` to print the live EDR headroom. The chosen level is remembered across
launches.

The keyboard's own brightness keys are not usable for this. macOS consumes them
below the layer where applications can observe events.

## How it works

Two independent stages.

**A one-pixel EDR window.** macOS raises the mini-LED backlight as soon as
extended-dynamic-range content is visible anywhere on screen, regardless of how
much of it there is. A 1×1 window in the corner, holding a `CAMetalLayer` with
`wantsExtendedDynamicRangeContent` and a clear colour above 1.0, is enough to
keep the panel in HDR mode. It redraws at 5 fps.

**A scaled gamma table.** `CGGetDisplayTransferByTable` reads the display's
current ramp; every entry is multiplied by the boost factor and written back
with `CGSetDisplayTransferByTable`. While the panel is in HDR mode, values
above 1.0 address the range beyond SDR white.

The gamma ramp is applied at the very end of the display pipeline, so it covers
everything uniformly: hardware video planes, Space transitions, the cursor,
full-screen apps. Nothing is composited over anything, so nothing can turn
white.

The factor is re-evaluated four times per second and clamped to the headroom
macOS currently reports, which produces a smooth ramp as the backlight rises
over the first few seconds.

### The approach that does not work

`alternatives/overlay-multiply.swift` keeps the first implementation: a
full-screen transparent window whose layer multiplies with the desktop behind
it. It is instructive because it *almost* works. It fails wherever the
compositing filter has no backdrop to multiply with, and there the layer falls
back to drawing its own colour, which is white. In practice that means any
video promoted to a hardware display plane, and every Space transition. It is
kept here as a documented dead end, not as a fallback.

## Caveats

- The backlight runs in HDR mode continuously. Expect noticeably higher power
  draw and a warmer chassis.
- It writes the display gamma table, so it conflicts with anything else that
  does: f.lux, Gamma Control, some calibration tools. Night Shift and True Tone
  are fine.
- Colour-critical work should not be done with a scaled gamma ramp.
- The original ramp is restored on quit, on `Ctrl-C`, and by CoreGraphics itself
  if the process dies. If a display is ever left too bright, run
  `overnits --boost 1.0 --seconds 1`.

## Credits and licence

The technique is not mine. I found it by reading
[BrightIntosh](https://github.com/niklasr22/BrightIntosh) by Niklas Rousset,
which is the mature implementation of the same idea and the one to use if you
want multi-display handling, sleep and battery awareness, incompatible-app
detection, and settings. `overnits` is an independent implementation, written
to be small and readable rather than complete.

[BrightXDR](https://github.com/starkdmi/BrightXDR) is the earlier project that
used the full-screen multiply overlay, and documents the same white-screen
symptoms reproduced in `alternatives/`.

Only public APIs are used: AppKit, Metal, MetalKit, CoreGraphics and Carbon
hot keys. No private frameworks, no entitlements, no accessibility permission.

Licensed under the GNU General Public License v3.0, matching BrightIntosh,
since the design was derived from reading it.
