# chicago/rdesktop — Remote Desktop

A module of the Chicago shell for the terminal desktop
([chicago/shell](https://github.com/chicago-desktop/shell)): **Remote Desktop**
in Start → Programs → Accessories. Pick a computer of the network, Connect,
and drive its Chicago desktop: its screen in the window, this keyboard and
mouse on it, the window's size its screen size.

## The connection screen

The window opens on "Remote Desktop Connection". It has three parts:

- **The list**: the computers of the network, from `system.cluster.members()`
  read through the shell's `chicago.shell.config:system`, the same source as
  Network Neighborhood (a value or a reason for each field). This computer
  comes first, marked "(this computer)". A generated node id is captioned by
  the host name.
- **The buttons**: Connect (the default) and Cancel.
- **The status line**: what the network is. "N computers on the network",
  "No other computers are on the network", "The network is off: this
  computer is not in a cluster", or the reason the membership could not be
  read.

To connect: double-click a row, press Enter on the list, or press Connect.
The arrows move the selection, Esc is Cancel, F5 reads the network again.

Only what is known is shown. The membership says which computers are in the
cluster and the address each advertises. It does not say whether a computer
serves Remote Desktop, whether it is reachable, or what role any node but
this one has. So there is a Computer column, an Address column only when a
member advertises one, and no "Status" column, which would say "Online" for
every member and measure nothing.

The logon is not this window's. The remote computer asks for it with its own
"Welcome to Chicago" inside the session; the screen ends at Connect.

A refused connection comes back to this screen: the computer is not
accessible, it does not offer the desktop, or it did not answer. An ended
session comes back too: the desktop was shut down, its node left, or its
server died. The reason stands whole above the buttons, so the person can
connect again without closing the window.

Args: `{"computer": "<node id>"}` connects to that computer at once and skips
the screen; this is how Network Neighborhood can open it for a node. A
failure there still lands on the screen with the reason. No args shows the
screen.

Two transports carry a session, behind one interface (below):

- **mesh** — the window's transport. The desktop runs on the node picked on
  the connection screen, served there by that node's **broker**.
- **loopback** — the desktop in a local tty viewport on this node, started
  with the window's own rights. It proves the viewer half without a network.

**Precondition for the mesh:** each node's `relay.node_name` must equal its
`cluster.name`. A PID carries the relay's node id and
`system.cluster.members()` reports `cluster.name`; the broker's name, the
viewer's lookup and each side's check of the other both glue these into
one. If the two differ, a viewer addresses a node that does not exist and
nothing says so.

## Inside

- `chicago.rdesktop:window` — "Remote Desktop Connection", an SDK window.
- `chicago.rdesktop:session` — the session window, an SDK window whose tree
  is the `terminal` view; it forwards keys (and the mouse and pastes once the
  SDK passes them) and resizes the remote screen with itself.
- `chicago.rdesktop:connect` — the connection screen as data: the computers,
  the tree, what each action does; pure.
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

## The session window: the remote screen in the SDK's terminal view

The session window is an ordinary SDK window (`app.main`, `pixel_render`).
Its tree is one `terminal` view (chicago/shell 0.4.2) holding the remote
rows and cursor:

- **In pixels** each row is decoded and drawn in the shell's mono face.
- **In cells** the rows are placed as they came.

**The remote screen is measured in mono columns when there are pixels, not
in terminal cells.** It is `(client width × cell width) // ui.MONO_PX`: 58
cells of 10 px hold 72 columns. The window opens the remote side at that
size and resizes it to that size, so the remote desktop lays itself out on
the grid it is drawn on. In cells a column is a cell.

**Pictures** (runtime d20096ed, chicago/shell 0.4.6).
- The viewer sends its grid in `open` (`g`: a mono column wide, a row high).
- The serving session tells its desktop, BEFORE the desktop starts, that it
  has graphics on exactly that grid (`view:terminal`). The desktop then lays
  its pixel chrome out for our pixels, and nothing is scaled.
- Every frame carries the pictures standing on the remote screen (`p`), and
  the terminal view draws them over the rows.
- A picture's pixels (PNG, base64) travel once per `(serial, version)` per
  session: the identity the picture keeps across the viewport. Later frames
  name it by that pair, with its geometry alone. **The cache is a condition
  of working, not an optimisation**: a wallpaper re-sent with every
  keystroke would fill the unbounded queue between the nodes.
- A new `open` starts with an empty cache on both sides, so a reopened window
  is sent everything again.
- A viewer in cells sends no `g`: its desktop stays in cells and no picture
  is sent.

**Pictures reach the window as PNG bytes, never as rasters** (chicago/shell
0.5.0). The session window's tree is PUBLISHED to the compositor, and a
`gfx` raster does not survive being sent to another process: it arrives nil.
v0.3.0 put rasters in the tree. Its tests drew the tree in the process that
built it and were green, while a live terminal showed white rectangles
where the remote windows were. Now each picture goes into the terminal view
as `{id, key, png, serial, version, x, y, cols, rows, z}`. `key` is
`<node>:<session>:<id>`, because a serial is counted per process and two
nodes can repeat one. The compositor's renderer decodes each picture once.
The evidence is a render in ANOTHER process (`app:render_probe`, fed the
tree through `process.send` as `publish_state` sends it), never one in the
window's own.

**End to end** (runtime 91dcbee8, which answers a viewport producer's
graphics probe from the viewport). The served Chicago desktop comes up in
pixels, and its chrome arrives as pictures: the taskbar (`bars`), the desktop
icons, the Start menu (`menu:<n>`). A cold desktop is ~5.6 KB of pixels, and
opening the Start menu adds ~11 KB once — over the wire. Between the
session window and its compositor (one process to another on the same node)
every publish carries all the PNGs on screen, ~10-15 KB with a menu or a
window open. That is measured, not yet optimised. `test/shots/session.png`
is that remote desktop, drawn in another process after the tree crossed the
boundary.
`view:terminal` takes integer sizes.

**The mouse and pastes** (chicago/shell 0.4.3). A pointer standing on the
view reaches the window with the column and row of the remote screen. The
SDK works them out (`ui.terminal_at`: the middle of the cell, on the mono
grid), and the window sends them on unchanged. It never computes a column
from a cell itself. A pointer off the view is swallowed by the SDK, as for
every window. The view fills the client, so that is only a drag released
outside the window. Pastes go to the remote desktop as they are.

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
other key, Esc included, goes to the remote desktop unchanged in both modes
while a session is on; on the connection screen Esc is Cancel.

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

**Ends.** The window never dies silently. The session window hands the
reason back to the connection window.

- Serving side: the session cancels its desktop and exits when the viewer
  closes it, when the viewer's process exits, when the viewer's node
  leaves, or when the membership says the node is gone (checked every 2 s).
  If the membership cannot be read (a node that lost its quorum answers
  nothing), the session holds on, but with a ceiling: with no message from
  the viewer and no membership confirming it for 30 s, it ends. Not knowing
  is not leaving, and it is not staying for ever either (`wire.judge`).
- Viewer side: the same, mirrored — `closed` / `failed`, the serving
  session's exit, its node leaving, the membership, the same ceiling.
- **A departed node is a LINK_DOWN, not an EXIT.** When a node leaves, the
  runtime sends LINK_DOWN to every local process that monitors *or* links a
  pid there (`system/topology` `HandleNodeExit`). A process without
  `trap_links` is terminated by it ("linked process failed").
  - Found on the two-node stand: the viewer's window vanished at "node
    left", and the serving session died without ending its desktop.
  - Fix: every session process traps links before its first monitor or link
    (`exits.trap`), and `exits` delivers LINK_DOWN as an end, like EXIT.
- **`process.cancel` does not kill.** It only delivers `pid.cancel` to the
  target's events, and its deadline ends nothing. The compositor acts on it
  like Shut Down, which waits for its windows; a process that does not act
  on it runs on. So a session ends its desktop in three steps: a cancel,
  the grace (`CLOSE_GRACE` 5 s, waiting for the exit), then
  `process.terminate` — the way the runtime's SSH host does it
  (`service/terminal/ssh.go`, `cancel`). A cancel refused by the policy
  returns `nil, err`, never an error raised. Once `serving` lacked
  `process.cancel`, and every served desktop outlived its session silently
  on the two-node stand. `serving` and `session_spawn` now carry both
  `process.cancel` and `process.terminate`, and every refusal is logged.
- The desktop is also **linked** to its serving session
  (`spawn_linked_monitored`, loopback too). A session that dies abnormally
  takes its desktop with it. A link does nothing on a normal exit — hence
  the terminate above.
- A refused spawn raises rather than returns, so a session can die before
  it answers. The broker watches its sessions and tells the viewer
  `failed` with the error, never a timeout.

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

- **Proven on two nodes (2026-09-18):**
  - both directions connect;
  - kill -9 of the serving node → the window is back on the connection
    screen with "The connection to <node> was lost." in ~4.7 s;
  - kill -9 of the viewer's node, a closed window or a dropped SSH session →
    the served desktop is gone (18 ms – 4.6 s).
- **Proven by harness tests only, not live:**
  - the terminate after the grace — on the stand the desktop always obeyed
    the cancel; covered by `app:stubborn`;
  - an abnormal death of the viewer's process — the stand could only end it
    normally; covered by `app:viewer_probe`.
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
