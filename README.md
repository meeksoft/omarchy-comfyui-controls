# ComfyUI Control for Omarchy

An Omarchy bar panel for starting, monitoring, and opening one local ComfyUI
server.

## Status

The first development version includes a themed Omarchy panel, read-only
ComfyUI status and queue monitoring, live progress events, output previews, and
a single-instance controller.

## Requirements

- Omarchy Quattro with the Omarchy shell plugin system
- A systemd user session (`systemd-run --user`, `systemctl --user`, `journalctl --user`)
- Python 3 — the bundled controller has no third-party dependencies
- A local ComfyUI checkout, with its own virtual environment or a Python you specify
- `notify-send` for execution-failure notifications

ComfyUI 0.34 or newer is recommended. See [Progress reporting](#progress-reporting).

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

## Install from a local checkout

Until the first release, add the repository as a development copy under the
Omarchy user plugin directory. From the repository root:

```bash
ln -s "$PWD" "$HOME/.config/omarchy/plugins/meeksoft.comfyui-controls"
omarchy plugin enable meeksoft.comfyui-controls
omarchy restart shell
```

For a published repository, use Omarchy's standard command instead of creating
the local development link:

```bash
omarchy plugin add REPOSITORY_URL --enable
```

Third-party Omarchy plugins execute as the current user. Review the repository
before enabling it.

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

The controller refuses to start a server on any host other than `127.0.0.1`,
`localhost`, or `::1`.

## Usage

The panel refreshes on its configured interval. It can safely attach to an
existing server, and only offers **Stop** for a server it started itself.

When the panel is focused, press `P` to expand the latest output, `J` to toggle
the jobs list, `E` to toggle diagnostics, `R` to refresh, `O` to open ComfyUI,
or `A` to dismiss an active alert. Right-click opens ComfyUI; middle-click
refreshes.

Error and crash states raise a desktop notification and show a dismissable
badge in the bar.

### Progress reporting

ComfyUI 0.34+ only sends progress events to the client that submitted the
prompt, so the panel reads step progress from a log file the managed server
streams in real time (tqdm sampler bars) and falls back to an indeterminate
bar. ETA is therefore labeled as a current-node estimate rather than a promise
for the entire workflow.

## Remove

If installed from Git, use Omarchy's standard removal command:

```bash
omarchy plugin remove meeksoft.comfyui-controls
```

For a local development link, disable the plugin and unlink that exact path:

```bash
omarchy plugin disable meeksoft.comfyui-controls
unlink "$HOME/.config/omarchy/plugins/meeksoft.comfyui-controls"
omarchy restart shell
```

Stopping the plugin does not stop a ComfyUI server you started yourself.

## Development

The plugin ID is `meeksoft.comfyui-controls`. The display name is
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

### Tests

```bash
python3 -m unittest discover -s tests -v
```

## Privacy and security

- No credentials are stored in this repository.
- The controller talks only to a loopback ComfyUI server and refuses non-local hosts.
- Runtime state and logs are written beneath the user's XDG data directory,
  with `0600` files in a `0700` directory, never into this repository.
- The panel stops only the systemd user unit it started itself.
- Machine-specific paths live in the user's Omarchy configuration and are
  ignored by Git.

## License

MIT
