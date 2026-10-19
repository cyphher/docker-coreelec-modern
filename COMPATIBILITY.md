# Compatibility

`docker-coreelec.sh` always installs the latest stable Docker, Compose and Buildx, unless a version is pinned with `DOCKER_VERSION` and friends. This page records which upstream versions have been reviewed against the project, and what was found.

- **CI checks** come from the daily [upstream-check](.github/workflows/upstream-check.yml) workflow. It checks that the aarch64 tarball has every binary the script needs, that the real `dockerd` accepts the `daemon.json` the script writes, and that the Compose and Buildx assets and checksums exist.
- **Review** is the weekly look at release notes and deprecations (see [MAINTENANCE.md](MAINTENANCE.md)).
- **Hardware** is a real install on a CoreELEC box. Please report yours in an issue.

| Reviewed | Docker | Compose | Buildx | CI checks | Review notes | Hardware |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-10-09 | 29.9.0 | – | – | pending first run | First review, see below | not yet |
| 2026-10-12 | 29.9.0 | v5.6.0 | v0.38.0 | pass (2026-10-09 to 2026-10-11) | Compose/Buildx baseline; CoreELEC not checked, see below | not yet |
| 2026-10-16 | 29.9.1 | v5.6.0 | v0.38.0 | not part of this change | Fresh-install bug found on hardware, fixed in 1.0.1; start-order bug and leftover failed unit found in an update, fixed in 1.0.2; see below | Odroid C4, CoreELEC 22.0-Piers nightly 20261016: fresh install worked with a `PATH` workaround; update with 1.0.1 rolled back (start order) |
| 2026-10-19 | 29.9.1 | v5.6.0 | v0.38.0 | pass (2026-10-15 to 2026-10-18) | Patch release, nothing breaking; see below | (see 2026-10-16) |

## Notes per review

### 2026-10-19: Docker 29.9.1

- Docker 29.9.1 (2026-10-14) is a patch release: containerd v2.4.2 in the static tarball (three security fixes for crashes and disk exhaustion during image pulls), and bug fixes for `--link-local-ip`, `docker ps -s`, `docker save`, the `fluentd` log driver, registry mirrors, plugins, firewalld zones and rootless `--domainname`.
- Nothing touches the `daemon.json` keys the script writes, `dockerd --validate`, the minimum API version, cgroup v1, old kernels, storage drivers, the containerd image store, iptables/nftables, systemd or `docker-proxy`. The firewalld changes do not apply: CoreELEC has no firewalld.
- The deprecations page has no new entries since the 29.x review. Removal of `docker commit --pause` and of the legacy links environment variables is targeted for v30.0; the script uses neither.
- The tarball contents are unchanged (daily check: all expected binaries present, no new files).
- Compose v5.6.0 and Buildx v0.38.0 are unchanged and still the latest releases (checked with the git tags). Their GitHub release pages could not be read in this run; the daily check confirms the asset names and checksum files.
- CoreELEC: no release since 22.0-Piers_beta2 (2026-09-07), so no change to the Kodi Docker add-on or the userspace architecture.
- No code change needed. Docker 29.9.1 was already used in the hardware test of 2026-10-16.

### 2026-10-16: first hardware report, fresh install

- Box: Odroid C4, CoreELEC 22.0-Piers nightly 20261016, kernel 5.15.196, aarch64, cgroup v2. No Docker installed before.
- Versions: Docker 29.9.1, Compose v5.6.0, Buildx v0.38.0.
- With 1.0.0, `install` stopped before changing anything: `dockerd --validate` refused the new `daemon.json` with `invalid userland-proxy-path: userland-proxy is enabled, but userland-proxy-path is not set`. dockerd looks up `docker-proxy` in `PATH`, and on a fresh install the new binaries were only in `/storage/.docker/update-tmp/docker`. Updates were not affected because an older `docker-proxy` was in `PATH`, and the daily check missed it because the GitHub runner has its own `docker-proxy`.
- Workaround with 1.0.0: `PATH=/storage/.docker/update-tmp/docker:$PATH bash docker-coreelec.sh install`, which then completed.
- Fixed in 1.0.1: validation runs with the new binary directory first in `PATH`. The daily check now uses only the new release's binaries in `PATH`.
- Later the same day, a real update with 1.0.1 (`FORCE=1 docker-coreelec install`, Docker 29.9.1, 23 containers) found two more problems:
  - **Start order.** `qbittorrent` uses `network_mode: service:gluetun` and was listed before `gluetun`, so Docker refused to start it (`cannot join network namespace of a non running container: container gluetun is exited`). The update rolled back, and the rollback hit the same error (`WARNING: not running: qbittorrent`). A manual `docker start qbittorrent` afterwards worked.
  - **Leftover failed unit.** The failed background run stayed in `systemctl --failed` as `docker-coreelec-<time>.service`.
- Fixed in 1.0.2: containers that share another container's network start after the others, containers that did not start get up to 3 more tries before the check, and the background run uses `systemd-run --collect`.

### 2026-10-12: Compose and Buildx baseline

- Docker is unchanged at 29.9.0 (reviewed 2026-10-09).
- First recorded Compose (v5.6.0) and Buildx (v0.38.0) versions. The daily check confirms that the assets the script downloads still exist with the same names: `docker-compose-linux-aarch64` with its `.sha256`, and `buildx-v0.38.0.linux-arm64` with an entry in `checksums.txt`. No code change is needed.
- The release notes of Compose and Buildx and the CoreELEC announcements could not be read in this run (the websites were not reachable from the maintenance task). They should be checked in the next review.

## Notes per Docker version

### 29.x (reviewed 2026-10-09)

- **Minimum API version is now 1.44.** Older clients, such as Portainer before 2.33.5 LTS, cannot connect. The script supports `MIN_API_VERSION=1.24` for a transition period, and the README explains it.
- **The containerd image store is the default for new installs.** The script sets `"containerd-snapshotter": false` to keep overlay2, so existing images keep working and rollback stays possible.
- **cgroup v1 is deprecated** but supported until at least May 2029. Many CoreELEC boxes still use cgroup v1 on kernel 4.9.
- **Options that newer Docker refuses** are no longer accepted: `cluster-store`, `cluster-advertise`, `cluster-store-opts` (removed in 23.0), `overlay2.override_kernel_check` (24.0), `oom-score-adjust` (25.0) and `api-cors-header` (28.0). `allow-nondistributable-artifacts` is deprecated as of 28.0. Several of these appear in the tamusiunas `daemon.json`, which `dockerd --validate` therefore rejects; the script then replaces it.
- **Docker 28's networking hardening** (FORWARD policy, unpublished ports) only affects containers on bridge networks. Host-network containers, such as a typical WireGuard or Pi-hole setup, are not affected.
