# docker-coreelec-modern

A current, 64-bit Docker Engine for [CoreELEC](https://coreelec.org), installed and kept up to date with one script.

Most CoreELEC builds run a 64-bit kernel with a 32-bit userspace, and the Docker add-on in the Kodi repository follows the userspace. The result is a 32-bit Docker that pulls `linux/arm` images, and many images have no 32-bit version at all. [tamusiunas/docker-coreelec](https://github.com/tamusiunas/docker-coreelec) solved this in 2021 by building a 64-bit Docker, but it stopped at a 2022 beta (22.06).

This project takes a simpler route. It installs the **official static aarch64 binaries** from [download.docker.com](https://download.docker.com/linux/static/stable/aarch64/), together with Docker Compose v2 and Buildx from their GitHub releases. Nothing is compiled. Updating is one command, and every change can be undone.

> **Status: beta.** The script has an automated test suite (see [Testing](#testing)), but it still needs reports from real boxes. If you try it, please open an issue with your device, CoreELEC version and the result.

## What it does

`docker-coreelec.sh install` works out what your box has now and acts on it:

| You have now | What happens |
| --- | --- |
| No Docker | Fresh install |
| The Kodi **Docker add-on** (`service.system.docker`) | **Migration.** The add-on is switched off and moved into a backup. Your containers, images and volumes are kept, and the containers are started again on the new Docker |
| **tamusiunas/docker-coreelec** | **Upgrade** in place. Containers, images and volumes are kept |
| docker-coreelec-modern | **Update** to the latest stable Docker, Compose and Buildx |

Every run follows the same safe sequence:

1. **Download and test first.** This happens while you watch, before anything is stopped:
   - all binaries are downloaded;
   - Compose and Buildx are checked against their published checksums;
   - the binaries are run once to make sure they work on your box;
   - the `daemon.json` that will be used is validated by the new `dockerd`;
   - free space for the backup is checked.

   Doing all this first matters because once a Pi-hole or VPN container stops, your network may be gone.
2. **Back up.** The current binaries, configuration and Docker's metadata are saved: container definitions, image index and networks. Image layers, volumes and container logs are not copied; the update does not touch them.
3. **Install and start.** The containers that were running are started again, as are systemd services that depend on Docker. Containers started with `--rm` are left to whatever started them, usually such a service. Monitoring containers are stopped first and started last (see [Start and stop order](#start-and-stop-order)).
4. **Roll back automatically** if Docker does not start, or if a container or service that was running before does not come back. The same happens if anything fails after Docker has been stopped. If nothing had been changed yet, only the previous Docker is started again.
5. **Keep running when your connection drops.** If you manage your box over a VPN that runs in Docker (WireGuard, Tailscale, ...), your SSH session drops as soon as the containers stop. The script runs in the background and finishes or rolls back by itself. Reconnect after a minute or two and read the log.

## Requirements

- CoreELEC on a box with a **64-bit kernel**. Check with `uname -m`: it must say `aarch64`. The script refuses to run otherwise.
- SSH access as root.
- About 500 MB free on `/storage`.
- Internet access from the box: `download.docker.com` and `github.com`.

## Install

Log in over SSH, then run:

```sh
curl -fsSL https://raw.githubusercontent.com/cyphher/docker-coreelec-modern/main/docker-coreelec.sh -o /storage/docker-coreelec.sh
bash /storage/docker-coreelec.sh status     # look before you leap
bash /storage/docker-coreelec.sh install
```

The script shows what it is going to do and asks for confirmation. It then follows its log until the job is done; Ctrl+C only stops following the log, not the install.

Afterwards the tool is available as `docker-coreelec` (open a new SSH session first so your `PATH` is updated):

```sh
docker-coreelec status
docker-coreelec self-update   # newest version of this tool
docker-coreelec update        # newest Docker
docker-coreelec rollback
```

> Save the script to a file as shown, do not pipe it into `bash`: it needs a file to restart itself in the background.

## Commands

| Command | |
| --- | --- |
| `status` | Current setup, installed and latest versions, running containers, containers still on 32-bit images, backups |
| `install` / `update` | Fresh install, migration, upgrade or update (see above) |
| `rollback` | Restore the state from before the last install/update, including the Kodi add-on after a migration |
| `uninstall` | Remove Docker. Images, containers, volumes and backups are kept; add `--purge` to delete them as well |
| `self-update` | Replace the script with the newest version from this repository. Run it before `update` to get the latest fixes |

Add `-y` to skip the confirmation question.

Environment variables:

| Variable | |
| --- | --- |
| `DOCKER_VERSION=29.9.0` | Install a specific Docker version instead of the latest |
| `COMPOSE_VERSION=v2.40.3` | Install a specific Compose version |
| `BUILDX_VERSION=v0.29.1` | Install a specific Buildx version |
| `MIN_API_VERSION=1.24` | Write `min-api-version` into a **new** `daemon.json`, so older API clients keep working (see [Portainer](#portainer)) |
| `FORCE=1` | Reinstall even if everything is up to date |
| `MONITOR_NAMES="pinger grafana"` | Treat these containers (by name, space or comma separated) as monitoring containers, see [Start and stop order](#start-and-stop-order) |

Example: `DOCKER_VERSION=29.9.0 bash /storage/docker-coreelec.sh install`

## Start and stop order

During an install, an update, the automatic rollback and `rollback`, containers are stopped and started in this order, so monitoring tools do not see the other containers go down and come back, and do not flood you with alerts:

- **Stopping:** monitoring containers first, then all others.
- **Starting:**
  1. normal containers;
  2. containers that use another container's network (`network_mode: service:gluetun` in Compose);
  3. monitoring containers, last.

  A container that still does not run is started again, up to 3 times; the final check covers all containers.

A container counts as a monitoring container when:

- its image repository name (the part after the last `/`, without registry, tag or digest, not case-sensitive) is one of `uptime-kuma`, `beszel`, `beszel-agent`, `netalertx`, `gatus`, `healthchecks`, `netdata`, `scrutiny`, `smokeping`, `speedtest-tracker` or `dozzle`. For example `louislam/uptime-kuma:2`, `ghcr.io/netalertx/netalertx` and `lscr.io/linuxserver/healthchecks` all match. Watchtower is not on the list: it updates containers, it does not monitor them;
- or it has the label `docker-coreelec.order=last` (in Compose: `labels: ["docker-coreelec.order=last"]`; a label can only be added when the container is created);
- or its name is in `MONITOR_NAMES`, for example `MONITOR_NAMES="grafana pinger" bash /storage/docker-coreelec.sh update`.

Is a monitoring image missing from the list? Please open an issue or a pull request; the list is `MONITOR_IMAGES` near the top of the script.

## After migrating from the Kodi add-on

- **Your existing containers keep their 32-bit images.** They still run, because the 64-bit kernel runs 32-bit programs fine. `docker-coreelec status` lists them. To move a container to 64-bit, pull its image again and recreate it: with `docker compose pull && docker compose up -d`, or in Portainer with *Recreate* and *Pull latest image* switched on. New containers get 64-bit images automatically.
- **Docker's data** moves from `/storage/.kodi/userdata/addon_data/service.system.docker/docker` to `/storage/.docker/data-root`. This is an instant move on the same disk. If the data lives on another disk, on a mount, or behind a symlink, it stays where it is and `daemon.json` points there.
- **Systemd units in `/storage/.config/system.d`** that start containers with the add-on's `docker` binary (like the add-on's examples) are switched to the new binary and started again. Rollback puts the originals back. References in `autostart.sh` or cron are reported but not changed.
- **Extra options** from the add-on's `docker.conf` (anything other than data-root and storage driver, for example `--dns`) are not carried over. The script lists them; add them to `/storage/.config/docker/daemon.json` yourself.
- **Reboot once** at a convenient moment, so Kodi forgets the old add-on.
- **Rolling back after that reboot** puts the add-on back and starts it. If Kodi then shows it as disabled, enable it again under *Add-ons → My add-ons → Services → Docker*.

## Portainer

Docker 29 no longer accepts clients that speak an API older than 1.44. Older Portainer versions are such a client: they cannot connect to the local environment until updated. Update Portainer to **2.33.5 LTS or newer**.

Before updating Portainer, back it up via *Settings → General → Back up Portainer*. The backup includes your stacks, custom templates and settings. Portainer upgrades its database on first start and cannot go back to an older version.

If you cannot update Portainer straight away, install with `MIN_API_VERSION=1.24`. When Portainer is updated, remove the `min-api-version` line from `/storage/.config/docker/daemon.json` and restart Docker with `systemctl restart docker`.

## Where things live

| Path | |
| --- | --- |
| `/storage/.docker/bin` | `dockerd`, `docker`, `containerd`, `runc`, ... |
| `/storage/.docker/cli-plugins` | `docker compose` and `docker buildx` (`docker-compose` also works) |
| `/storage/.docker/data-root` | Images, containers, volumes (default location) |
| `/storage/.docker/backup` | The last 3 backups |
| `/storage/.config/docker/daemon.json` | Docker configuration |
| `/storage/.config/system.d/service.system.docker.service` | The systemd service, also reachable as `docker.service` |
| `/storage/docker-coreelec.log` | Log of the last run (`.log.old` for the one before) |

### Default configuration

A new `daemon.json` contains:

```json
{
  "data-root": "/storage/.docker/data-root",
  "storage-driver": "overlay2",
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "journald",
  "group": "root",
  "live-restore": true,
  "features": { "containerd-snapshotter": false }
}
```

- `containerd-snapshotter: false` keeps the classic overlay2 image store instead of Docker 29's new containerd store. That keeps existing images working, uses less space on small eMMC storage, and keeps a rollback possible.
- `journald` logging means `docker logs` works and logs do not fill up `/storage`.

On an update, an existing `daemon.json` is checked with `dockerd --validate` from the **new** version. If it is valid, it is kept as is. If not, for example the tamusiunas config with options that newer Docker refuses, it is saved in the backup and replaced by the default above, with your data-root. The script shows what Docker objected to.

## Manual recovery

If the log ends with *Docker could not be brought back automatically*, nothing has been deleted. Try these, in order:

1. **Reboot the box.**
2. **Run `bash /storage/.docker/docker-coreelec.sh rollback`**, or the copy in `/storage` if that one is gone.
3. **Restore by hand.** Each folder in `/storage/.docker/backup` holds a complete copy of the previous setup:
   - `bin/`, `cli-plugins/`, `daemon.json` and the service file;
   - after a migration, the Kodi add-on in `addon/`;
   - in `meta`, where Docker's data was.

   Copy these back, then run `systemctl daemon-reload && systemctl restart docker`.

Please open an issue with the log (`/storage/docker-coreelec.log`) so it can be fixed.

## Troubleshooting

- **`invalid userland-proxy-path: ... userland-proxy-path is not set`** during a fresh install: fixed in 1.0.1. With 1.0.0, download the script again (see [Install](#install)), or run `PATH=/storage/.docker/update-tmp/docker:$PATH bash /storage/docker-coreelec.sh install`.
- **`cannot join network namespace of a non running container`** during an update or rollback (for example `qbittorrent` with `network_mode: service:gluetun`): fixed in 1.0.2, which starts such containers after the one whose network they use. With 1.0.1, start the container by hand afterwards: `docker start qbittorrent`.
- **A failed `docker-coreelec-<number>.service` in `systemctl --failed`**: left behind by a failed run before 1.0.2; the outcome is in `/storage/docker-coreelec.log`. Remove it with `systemctl reset-failed`.
- **`self-update failed: could not download ...`**: the box could not reach `raw.githubusercontent.com`. Check its internet connection and DNS. The current script is left unchanged.

## Testing

`tests/run-tests.sh` runs every scenario against a simulated CoreELEC box, with mocked `docker`, `systemctl`, `systemd-run` and `curl`:

- fresh install, update with "already up to date", and update plus rollback
- tamusiunas upgrade with an invalid config
- Kodi add-on migration: with `--rm` containers managed by systemd units, without `docker.conf`, and with the data behind a symlink
- automatic rollback when Docker does not start, or when a container or service does not come back
- containers that share another container's network, and a container that needs a second start
- the stop and start order of monitoring containers, on update, rollback and automatic rollback
- failures injected at every step after Docker is stopped
- manual rollback, and a refused rollback when the add-on was installed again
- uninstall and `--purge`
- `self-update`, including a failed download
- a dropped SSH session, and settings surviving into the background run
- refusals

No box, root or network is needed. The suite and ShellCheck run on every push via GitHub Actions.

```sh
bash tests/run-tests.sh
```

## Staying current

The script always installs the latest stable releases. A daily GitHub Action tests every new Docker, Compose and Buildx release against the script. A weekly review checks the release notes for anything that could break CoreELEC installs. [COMPATIBILITY.md](COMPATIBILITY.md) lists what has been reviewed, and [MAINTENANCE.md](MAINTENANCE.md) describes the process.

## Credits

- [tamusiunas/docker-coreelec](https://github.com/tamusiunas/docker-coreelec), which showed that a 64-bit Docker on CoreELEC works and defined the `/storage/.docker` layout used here
- The LibreELEC and CoreELEC teams for the Docker add-on and the service handling it relies on
- Docker / Moby for the static binaries

This project is not affiliated with Docker, CoreELEC, LibreELEC or Kodi.

## License

[MIT](LICENSE)
