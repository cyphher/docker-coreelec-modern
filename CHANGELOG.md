# Changelog

## 1.0.0 (unreleased)

First version.

- Installs the official static aarch64 Docker binaries, Docker Compose v2 and Buildx
- Fresh install, migration from the Kodi Docker add-on, upgrade from tamusiunas/docker-coreelec, and updates
- Downloads and tests everything before stopping containers
- Backup before every change, automatic rollback if Docker or a container does not come back, manual `rollback`
- Runs in the background so a dropped SSH/VPN session does not interrupt it
- Keeps an existing `daemon.json` when the new Docker validates it
- `status`, `uninstall` and `uninstall --purge`
