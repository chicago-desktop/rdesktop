# chicago/rdesktop — Remote Desktop

A module of the Chicago shell for the terminal desktop
([chicago/shell](https://github.com/chicago-desktop/shell)): **Remote Desktop**
in Start → Programs → Accessories, a window that shows another Chicago
desktop and drives it — its screen in the window, this keyboard and mouse on
it, the window's size its screen size.

This version has one transport, the **loopback**: the "remote" desktop is a
Chicago shell started on this node, in a local tty viewport, on the base's
window host (`chicago.tui_desktop:workers`). It exists to prove the viewer
half without a network; a network transport takes its place later (below).

## Inside

- `chicago.rdesktop:window` — the window: a custom **cells** window with its
  own loop (the SDK's custom-window contract, `docs/sdk.md`), because its
  content is another desktop's styled terminal rows, which no declarative
  component carries. It opens a session, presents the remote rows, forwards
  keys, the mouse and pastes, and resizes the remote screen with itself.
- `chicago.rdesktop:loopback` — the loopback transport, behind the session
  interface below.
- `chicago.rdesktop:frames` — the remote screen as row deltas; pure.
- `chicago.rdesktop:inputs` — the key mode and the mouse pinning; pure.
- `chicago.rdesktop:session_spawn` — the policy that lets the window start,
  watch and cancel its desktop.
- `chicago.rdesktop:tip` — a "Did you know..." tip for the Welcome window.

## The session interface — the one boundary

The window reaches the remote desktop only through the library imported as
`transport` in its entry; switching to a network transport is that one
import line. A session has the shape of the runtime's tty Viewport
(`api/tty/service.go`, the `tty` module's Viewport) name for name, plus what
a viewport does not say:

- `transport.open{entry, host, width, height, args?}` — create the viewport, start the desktop with its grant → session, or nil and the reason
- `session:grant()` — always nil: the one-shot grant went to the desktop `open` started
- `session:handle()` — a local viewer handle (a remote session has none)
- `session:snapshot(after_revision)` — nil when the screen is still at `after_revision`, else a **delta** from it
- `session:updates()` — coalesced revision watermarks: "ask for a snapshot"
- `session:send(event)` — a key, mouse or paste event in remote coordinates
- `session:resize(width, height)` — the remote screen size
- `session:close()` — ends the remote desktop, releases the session; idempotent
- `session:ended()` — a channel that receives the reason once the remote desktop is gone

- **Deltas, not snapshots.** A viewport snapshot carries every row whenever
  anything changed. The transport hands the window only the rows that
  differ, computed on the producer's side (`frames.delta`); a full delta
  (every row) only first, after a size change, or when the viewer's
  acknowledgement does not match.
- **One frame in flight.** `after_revision` is the viewer's
  acknowledgement — the revision it has applied. The window asks for the
  next delta only after applying the previous, and a delta is cut from the
  live viewport when asked for, so the revisions between two asks are never
  sent: the wire carries the latest screen, not every screen. A network
  transport must keep this; a queue of frames towards a viewer that stopped
  reading is memory, not lost frames.

## Rows and a cursor only — no pixels

A viewport snapshot carries rows, a cursor and a revision, nothing else:
there are no images in `ttyapi.Snapshot`, and `system/tty/surface.Present`
drops a frame's placements without a word. So the remote desktop is always
shown as its **cells** rendering — a remote shell comes up with "pixels off"
on the viewport's port by itself — whatever the local desktop draws its own
chrome with. Pixels over this path are a separate stage that needs a change
to `api/tty`, not to this module.

## Keys the local desktop keeps

The local compositor takes some combinations before any window sees them:
Ctrl+Q, Alt+N, Alt+W, Alt+M, Alt+O and Alt+Tab. The window offers them to
the remote desktop on combinations that get through — as the Remote Desktop
client of Windows maps Alt+Tab to Alt+Page Up when "Windows key
combinations apply to" is not the remote computer:

- Alt+Page Up → Alt+Tab — its next window
- Alt+Page Down → Alt+Shift+Tab
- Alt+Home → Alt+O — its Start menu
- Ctrl+Alt+End → Ctrl+Q — its Shut Down
- Ctrl+Alt+N / W / M / O → Alt+N / W / M / O

That is the **remote** key mode, the default. The window opened with args
`{"keys": "local"}` forwards every key as it arrives and maps nothing. Every
other key, Esc included, goes to the remote desktop unchanged in both modes;
when the session has ended, Esc closes the window.

## Rights

The remote desktop runs under the window's own identity — the logged-on
person's actor and scope — so the window entry carries the shell's two
policies (`chicago.shell.security:shell_runtime`, `shell_env`) besides its
own `session_spawn`: a shell without them cannot even claim a desktop name,
and the window says so (`the remote desktop failed: no desktop name of
chicago.shell.desktop is free …`). The desktop it starts is fixed in
`window.lua` and never taken from the window's args: a caller-chosen entry
would run with those rights too. With a logon configured the remote desktop
shows "Welcome to Chicago" and asks for a password of its own, as a remote
computer does.

## Limits of the loopback

- The remote desktop and its windows run on the same
  `chicago.tui_desktop:workers` host as the local desktop's windows and take
  its slots (`max_processes: 16`). A network transport spends another node's.
- The mouse reaches the remote desktop where the local compositor forwards
  it: presses, releases, the wheel and captured drags; plain motion only
  where the compositor sends it.
- The remote shell's desktop name is the next of the family
  (`chicago.shell.desktop.2` …), so the command channel's first desktop stays
  the local one.

The module depends on `chicago/shell` (the desktop the loopback starts, its
policies) and `chicago/tui-desktop` (the compositor, its input normalizer,
its window host), both resolved from their GitHub repositories by tag
(`make setup`). It asks nothing of the application.

## Developing

```bash
make setup     # resolve the dependencies (once, and after changing them)
make check     # the repository's invariants
make lint      # late locals, then wippy lint of this namespace and the harness
make test      # the harness in test/: frames, inputs, the loopback end to end, the window under a narrow scope; screens as text in test/shots/
make publish   # publish a release, after `wippy auth login`
```

**A build of the runtime fork from its releases is required**
([chicago-desktop/runtime](https://github.com/chicago-desktop/runtime),
`v0.3.40a-chicago.2` or newer): it resolves the shell and the base from
GitHub by tag, and the shell declares the `gfx` module, which the release
runtime does not have — `wippy` from PATH does not load the shell at all.
The Makefile's `WIPPY` names the build; override it with `make test WIPPY=…`.

The window SDK is documented in [docs/sdk.md](docs/sdk.md), a copy of the
shell's guide, and the skill for agents in
[skills/wippy-window-app/SKILL.md](skills/wippy-window-app/SKILL.md); the
rules of this repository are in [AGENTS.md](AGENTS.md).

Made from [the Chicago module template](https://github.com/chicago-desktop/module-template) for
modules of the Chicago shell. Repository:
https://github.com/chicago-desktop/rdesktop.

## Licence

MIT.
