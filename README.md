# ComfyUI Control for Omarchy

An Omarchy bar panel for starting, monitoring, and opening one local ComfyUI
server.

## Status

The first development version includes a themed Omarchy panel, read-only
ComfyUI status and queue monitoring, live progress events, output previews, and
a single-instance controller.

## Planned features

- Start one local ComfyUI server without creating duplicates.
- Attach to an already-running healthy ComfyUI server.
- Distinguish ComfyUI from an unrelated process occupying the configured port.
- Show offline, starting, idle, generating, and error states.
- Show running and queued prompt counts.
- Show current generation progress and the latest available preview.
- Show observed/exact start time, elapsed time, and a smoothed current-node ETA.
- Expand running and pending job details.
- Keep output previews collapsed by default and show output metadata on demand.
- Surface recent execution failures and optionally summarize an external log.
- Open ComfyUI in the default browser.
- Stop only the server instance managed by this plugin.
- Surface useful startup diagnostics without exposing private configuration.

## Installation

Until the first release, clone the repository and add it as a development copy
under the Omarchy user plugin directory. Normal releases will be installable
with `omarchy plugin add`.

The panel can safely attach to an existing server. It only offers **Stop** for
a server it started itself.

When the panel is focused, press `P` to expand the latest output, `J` to toggle
the jobs list, `E` to toggle diagnostics, `R` to refresh, or `O` to open
ComfyUI.

## Configuration

The plugin manifest defines these per-user settings:

- ComfyUI folder
- Optional Python executable
- Server host and port
- Status refresh interval
- Optional external server log file
- Whether the latest output preview starts expanded

Machine-specific values belong in the user's Omarchy configuration. Do not add
absolute installation paths, credentials, generated images, or runtime logs to
this repository.

ComfyUI's progress events describe the active node. ETA is therefore labeled
as a current-node estimate rather than a promise for the entire workflow.

## Development

The plugin ID is `io.github.meeksoft.comfyui`. The display name is
**ComfyUI Control**, while the compact bar label is **ComfyUI**.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the initial process and
API design.

### Controller

The bundled controller has no third-party Python dependencies:

```text
bin/comfyui-control status [--host HOST] [--port PORT]
bin/comfyui-control start --root COMFYUI_FOLDER [--python PYTHON]
bin/comfyui-control stop
bin/comfyui-control interrupt
bin/comfyui-control watch
```

Finite commands print one JSON object. `watch` prints newline-delimited JSON
events until its WebSocket connection ends.

## License

MIT
