# Falix / Non-root container deployment notes

This image supports restricted runtimes that start the container as a non-root user.

On non-root startup, `DockerEntrypoint.sh`:

- Places the SQLite database and mutable data under `OMID_DATA_DIR` (default: `$HOME/omid-data`, with `/home/container/omid-data` as a fallback).
- Places logs, Xray/MTProto runtime files, geodata and the node-token key under that data directory unless their `XUI_*` paths are explicitly supplied.
- Copies bundled files from `/app/bin` into the writable runtime binary folder on first boot, without overwriting existing files on each restart.
- Disables Fail2ban because it requires root privileges and host firewall access. Application-level IP-limit UI/settings may remain visible, but host-level bans will not be enforced in this mode.
- Uses `/tmp` for Supervisor and Nginx PID files and avoids asking either service to switch to `root`.

The data directory must be writable and persistent in the hosting panel. A rebuild of the image does not automatically publish it; push the source changes and let the image build workflow publish a new tag, then select/pull that image in Falix and restart the server.
