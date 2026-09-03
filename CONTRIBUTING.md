# Contributing

Contributions are welcome while the plugin is taking shape.

- Keep tracked files portable and free of private machine data.
- Do not commit credentials, local paths, logs, generated media, or process IDs.
- Keep lifecycle operations in the controller rather than interpolating shell
  commands in QML.
- Never stop a server unless the controller can prove it owns that instance.
- Validate `manifest.json` and run the available tests before submitting work.
- Preserve keyboard navigation and current Omarchy theme behavior in the panel.

