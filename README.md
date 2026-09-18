# chicago/rdesktop — Remote Desktop

A module of the Chicago shell for the terminal desktop, in the look of the
mid-nineties desktops ([chicago/shell](https://github.com/chicago-desktop/shell)): it adds
**Remote Desktop** to the Start menu under Programs. Describe here what the
window does and how it is used.

## Inside

- `chicago.rdesktop:view` — the window as data: a pure library with the
  component tree of a model and what an action does to it; the tests
  exercise it without a compositor.
- `chicago.rdesktop:window` — the process: runs `view` on the shell's SDK
  (`chicago.shell.sdk:app`).
- `chicago.rdesktop:images` — the module's pictures, an image pack of the
  shell (`assets/images/{32,16}/<name>.png`), named
  `chicago.rdesktop:images/<name>`.
- `chicago.rdesktop:tip` — a "Did you know..." tip for the Welcome window
  (`meta.type: chicago.tip`); inert on a desktop without chicago/welcome.

The module depends on `chicago/shell` (the SDK, the image packs) and
`chicago/tui-desktop` (the compositor), both resolved from their GitHub
repositories by tag (`make setup`; no working copy of the shell is needed
beside the module). It asks nothing of the application.

## Developing

```bash
make setup     # resolve the dependencies (once, and after changing them)
make check     # the repository's invariants
make lint      # late locals, then wippy lint of this namespace and the harness
make test      # the harness in test/: the view, the window, a shot in test/shots/
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
