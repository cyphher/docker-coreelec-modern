# Changelog

## 1.0.1 (unreleased)

- Fix: a fresh install failed at the `daemon.json` check with `invalid userland-proxy-path: userland-proxy is enabled, but userland-proxy-path is not set`. `dockerd --validate` looks up `docker-proxy` in `PATH`, and on a box without Docker the new binaries were not in `PATH` yet. Validation now runs with the new binary directory first in `PATH`, so updates also check against the new `docker-proxy` rather than the old one. The daily upstream check does the same.
- `self-update`: a failed download now shows the URL, the HTTP status (or that there was no response), that the current script was not changed, and a hint.

## 1.0.0 (unreleased)

First version.

- Installs the official static aarch64 Docker binaries, Docker Compose v2 and Buildx
- Fresh install, migration from the Kodi Docker add-on, upgrade from tamusiunas/docker-coreelec, and updates
- Downloads and tests everything before stopping containers
- Backup before every change, automatic rollback if Docker or a container does not come back, manual `rollback`
- Runs in the background so a dropped SSH/VPN session does not interrupt it
- Keeps an existing `daemon.json` when the new Docker validates it
- `status`, `uninstall`, `uninstall --purge` and `self-update`
- `print-default-config` and `latest-versions` for maintainers and CI
- Daily upstream check and weekly review process (see MAINTENANCE.md)
