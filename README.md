# chicago/rdesktop — Remote Desktop

A module of the Chicago shell for the terminal desktop
([chicago/shell](https://github.com/chicago-desktop/shell)): **Remote Desktop**
in Start → Programs → Accessories, a window that shows another Chicago
desktop and drives it — its screen in the window, this keyboard and mouse on
it, the window's size its screen size.

Two transports carry a session, behind one interface (below):

- **mesh** — the window's transport. The desktop runs on a node of the
  cluster (`{"computer": "<node id>"}` in the window's args; none is this
  node), served there by that node's **broker**.
- **loopback** — the desktop in a local tty viewport on this node, started
  with the window's own rights. It proves the viewer half without a network.

**Precondition for the mesh:** each node's `relay.node_name` must equal its
`cluster.name`. A PID carries the relay's node id and
`system.cluster.members()` reports `cluster.name`; the broker's name, the
viewer's lookup and each side's check of the other both glue these into
one. If the two differ, a viewer addresses a node that does not exist and
nothing says so.

## Inside

- `chicago.rdesktop:window` — the window: a custom **cells** window with its
  own loop (the SDK's custom-window contract, `docs/sdk.md`), because its
  content is another desktop's styled terminal rows, which no declarative
  component carries. It opens a session, presents the remote rows, forwards
  keys, the mouse and pastes, and resizes the remote screen with itself.
- `chicago.rdesktop:mesh` — the mesh transport, the viewer's end of the
  session protocol.
- `chicago.rdesktop:broker` (+ `broker.service`) — "Remote Desktop is
  enabled on this computer": the node's resident broker.
- `chicago.rdesktop:host_session` — one served session, on the serving node.
- `chicago.rdesktop:wire` — the session protocol as Lua tables, and the one
  sender.
- `chicago.rdesktop:exits` — one reader of a process's lifecycle channel for
  every session in it.
- `chicago.rdesktop:loopback` — the loopback transport.
- `chicago.rdesktop:frames` — the remote screen as row deltas; pure.
- `chicago.rdesktop:inputs` — the key mode and the mouse pinning; pure.
- `chicago.rdesktop:viewing` — the window's policy on the mesh;
  `serving` — the broker's and its sessions'; `session_spawn` — a window's
  on the loopback.
- `chicago.rdesktop:process_host` — the requirement naming the host the
  broker runs on (default `app:processes`); sessions run on the same host.
- `chicago.rdesktop:tip` — a "Did you know..." tip for the Welcome window.

## The session interface — the one boundary

The window reaches the remote desktop only through the library imported as
`transport` in its entry; switching to a network transport is that one
import line. A session has the shape of the runtime's tty Viewport
(`api/tty/service.go`, the `tty` module's Viewport) name for name, plus what
a viewport does not say:

- `transport.open{node?, entry, host, width, height}` — create the viewport and start the desktop with its grant (loopback: here; mesh: on `node` through its broker, which only checks `entry` against what it offers) → session, or nil and the reason in words for the window
- `session:grant()` — always nil: the one-shot grant went to the desktop `open` started (on the mesh it is on the other node)
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

## The mesh: broker, sessions, wire

The runtime has no remote spawn. So every node that serves runs a
**broker** (`broker.service`, under its own actor `chicago.rdesktop.broker`).
The broker takes the name `chicago.rdesktop.broker@<node id>` in the
cluster's name registry, scope EVENTUAL. A viewer gets node ids from
`system.cluster.members()`, looks the name up and sends `open`. For each
`open` the broker spawns a `host_session` on its own host. That session
makes a local viewport, starts the desktop in it with the grant, answers
`opened` and then talks to the viewer directly. No broker under the name →
the window says: "The computer is not accessible. Remote Desktop is not
enabled on <node>."

The wire is the `Frame` of `runtime/service/rdesktop/protocol.go`, field for
field, as Lua tables on the topic `chicago.rdesktop`:

- `k` — the kind: open, opened, frame, ack, input, resize, close, closed,
  failed. The viewer sends open, ack, input, resize and close; the server
  sends opened, frame, closed and failed.
- `s` — the session: the viewer's number. The server keys on (viewer PID, s),
  so two viewers never collide.
- `r` — the revision a frame carries or an ack acknowledges.
- `x`, `y` — the size in cells, on open, resize, opened and every frame.
- `w` — ONLY the rows that changed since the acknowledged revision. The key
  is the row's zero-based index, written as a decimal string. A full screen
  is simply every row changed: the first frame, after a resize, after an
  ack that does not match.
- `c` — the cursor, zero-based `{x, y, visible}` as in api/tty. Only the Lua
  side converts to one-based.
- `e` — one terminal event; `n` — the desktop asked for on open (absent: the
  server's default); `m` — why a session closed or failed, in words for the
  window's last row.

**Row keys are strings on purpose.** Between nodes a Lua payload becomes Go
values (`engine/value.ToGoAny`) and then msgpack. A table whose `MaxN` is
above zero becomes a list `1..MaxN`, and every key after the first gap is
dropped without a word. Key 0 is never in that list. On one node the table
is handed over as it is, so a single-node test cannot see the loss.
`wire.send` is the only sender, and it refuses any message with a table
that is neither a gapless list nor string-keyed.

**One frame in flight.** The internode queue is unbounded and never refuses
(`cluster/internode/state_manager.go`, `newClassQueue` with a zero cap): a
stream of frames towards a wedged viewer grows the sender's memory. So the
session sends a frame, then nothing until the viewer acks it. The next
frame is cut fresh from the live viewport, and the revisions in between are
never sent. A frame goes out as soon as the ack allows, and the viewer keeps
it until its window asks, so the window does not wait on the network. The
ack goes out as the frame is handed over.

**Ends.** The window's last row always says why a session ended.

- Serving side: the session cancels its desktop and exits when the viewer
  closes it, when the viewer's process exits (monitor), or when the viewer's
  node leaves `system.cluster.members()` (checked every 2 s).
- Viewer side: the session ends on `closed` / `failed`, when the serving
  session's process exits, or when the serving node leaves the membership.

**Without a cluster** the runtime has no EVENTUAL registry ("eventual
registry not available"). Only then does the broker take its name locally
and serve viewers on its own node, with a warning in the log. Any other
refusal stops it.

**What a viewer can ask for.** The broker offers one desktop, the Chicago
shell. An `open` that names another entry is refused ("This computer does
not offer …").

## Rights

- **On the mesh** the desktop runs on the serving node under the broker's
  actor, whose service carries `serving` and the shell's two policies. The
  window needs only `viewing`. With a logon configured, the served desktop
  shows "Welcome to Chicago" and asks for a password of its own, as a remote
  computer does.
- **On the loopback** the desktop runs under the window's own identity, so
  the window would carry `session_spawn` plus the shell's two policies. A
  shell without them cannot even claim a desktop name, and the window says
  so ("… no desktop name of chicago.shell.desktop is free …").
- Either way the desktop is fixed in code and never taken from the window's
  args.

## Limits

- A served desktop and its windows take slots of the serving node's
  `chicago.tui_desktop:workers` host (`max_processes: 16`), shared with that
  node's own desktops. On the loopback, or on the mesh to this node, those
  are this node's slots.
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
make test      # the harness in test/: frames, inputs, wire, the loopback and the mesh end to end, the window under a narrow scope; screens as text in test/shots/
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
