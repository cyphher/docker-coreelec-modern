# Compatibility

`docker-coreelec.sh` always installs the latest stable Docker, Compose and Buildx, unless a version is pinned with `DOCKER_VERSION` and friends. This page records which upstream versions have been reviewed against the project, and what was found.

- **CI checks** come from the daily [upstream-check](.github/workflows/upstream-check.yml) workflow. It checks that the aarch64 tarball has every binary the script needs, that the real `dockerd` accepts the `daemon.json` the script writes, and that the Compose and Buildx assets and checksums exist.
- **Review** is the weekly look at release notes and deprecations (see [MAINTENANCE.md](MAINTENANCE.md)).
- **Hardware** is a real install on a CoreELEC box. Please report yours in an issue.

| Reviewed | Docker | Compose | Buildx | CI checks | Review notes | Hardware |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-10-09 | 29.9.0 | – | – | pending first run | First review, see below | not yet |

## Notes per Docker version

### 29.x (reviewed 2026-10-09)

- **Minimum API version is now 1.44.** Older clients, such as Portainer before 2.33.5 LTS, cannot connect. The script supports `MIN_API_VERSION=1.24` for a transition period, and the README explains it.
- **The containerd image store is the default for new installs.** The script sets `"containerd-snapshotter": false` to keep overlay2, so existing images keep working and rollback stays possible.
- **cgroup v1 is deprecated** but supported until at least May 2029. Many CoreELEC boxes still use cgroup v1 on kernel 4.9.
- **Options that newer Docker refuses** are no longer accepted: `cluster-store`, `cluster-advertise`, `cluster-store-opts` (removed in 23.0), `overlay2.override_kernel_check` (24.0), `oom-score-adjust` (25.0) and `api-cors-header` (28.0). `allow-nondistributable-artifacts` is deprecated as of 28.0. Several of these appear in the tamusiunas `daemon.json`, which `dockerd --validate` therefore rejects; the script then replaces it.
- **Docker 28's networking hardening** (FORWARD policy, unpublished ports) only affects containers on bridge networks. Host-network containers, such as a typical WireGuard or Pi-hole setup, are not affected.
