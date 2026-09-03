# ComfyUI Control for Omarchy

An Omarchy bar panel for starting, monitoring, and opening one local ComfyUI
server.

## Status

This repository is an early scaffold. The manifest and panel entry point are in
place; server control and ComfyUI API integration are the next milestones.

## Planned features

- Start one local ComfyUI server without creating duplicates.
- Attach to an already-running healthy ComfyUI server.
- Distinguish ComfyUI from an unrelated process occupying the configured port.
- Show offline, starting, idle, generating, and error states.
- Show running and queued prompt counts.
- Show current generation progress and the latest available preview.
- Open ComfyUI in the default browser.
- Stop only the server instance managed by this plugin.
- Surface useful startup diagnostics without exposing private configuration.

## Installation

Installation instructions will be added once the first usable release is
ready. Omarchy discovers third-party plugins under its user plugin directory;
normal releases will be installable with `omarchy plugin add`.

## Configuration

The plugin manifest defines these per-user settings:

- ComfyUI folder
- Optional Python executable
- Server host and port
- Status refresh interval

Machine-specific values belong in the user's Omarchy configuration. Do not add
absolute installation paths, credentials, generated images, or runtime logs to
this repository.

## Development

The plugin ID is `io.github.meeksoft.comfyui`. The display name is
**ComfyUI Control**, while the compact bar label is **ComfyUI**.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the initial process and
API design.

## License

MIT

