# Contributing

Read `AGENTS.md`, create a focused branch, and run `make verify` with a local
build of the runtime fork before opening a pull request. Everything in the
repository is English.

Pull requests must say which registry entry or contract they change, include
tests for public behaviour (the pure libraries in `test/src/frames_test.lua`
and `test/src/inputs_test.lua`, the transport in `test/src/loopback_test.lua`,
the window in `test/src/window_test.lua` and `window_run_test.lua`), and
attach or describe the screens in `test/shots/` when what the window shows
changed. Avoid unrelated formatting and
compatibility layers. Never commit credentials, `wippy.lock` files or local
Wippy state.
