# Architecture

## Scope

ComfyUI Control manages and observes one local ComfyUI server. It is not a
Comfy Cloud client and does not manage models, custom nodes, or workflows.

## Components

1. `Panel.qml` renders the Omarchy bar widget and popup.
2. `bin/comfyui-control` owns server lifecycle operations and emits structured
   JSON responses.
3. `Service.qml` reads health, queue, progress, history, and preview
   information from the local server APIs.

QML should not infer process state from terminal output or assemble shell
commands from user-provided paths.

## Single-instance contract

Starting the server must follow this sequence:

1. Acquire a runtime lock scoped to the configured host and port.
2. Probe the configured endpoint for a valid ComfyUI response.
3. If ComfyUI is healthy, attach to it and report `running`.
4. If another process owns the port, report `foreign-port` and take no action.
5. If the port is free, launch one transient user service with a randomized
   unit name and record its ownership in the user's XDG state directory.
6. Verify ComfyUI becomes healthy before reporting `started`.

Stopping must affect only a process started and tracked by the controller. The
plugin must never kill an arbitrary process based solely on a matching port or
process name.

## State model

- `offline`: no listener and no managed startup in progress
- `starting`: managed launch requested, health check not ready
- `idle`: healthy server with no active or pending prompts
- `generating`: healthy server with an active prompt
- `queued`: healthy server with pending work but no active execution
- `foreign-port`: configured port is occupied by something other than ComfyUI
- `error`: controller or API failure with a user-actionable message

## Public-data policy

Tracked files must not contain personal names, email addresses, credentials,
access tokens, machine hostnames, private repository URLs, absolute user paths,
or local ComfyUI installation paths. Examples use placeholders or standard
defaults only.

Runtime files should use XDG runtime, state, cache, and configuration locations.
They must remain untracked and must not be included in diagnostics by default.
