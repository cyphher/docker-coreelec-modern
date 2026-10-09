# Maintenance

How this project keeps up with Docker, Compose, Buildx and CoreELEC.

The script downloads the latest versions at install time, so a new Docker release does **not** need a code change by itself. Maintenance means noticing when a release *breaks* something, such as a removed `daemon.json` option, a changed tarball, a renamed asset or a CoreELEC change to the Kodi Docker add-on, and fixing it before users hit it.

## The pipeline

```
 daily     GitHub Action "upstream-check"
           mechanical checks with the real new binaries
                 │  writes status.json to branch "upstream-status"
                 │  opens an issue labelled "upstream" if a check fails
                 ▼
 weekly    Claude maintenance task (cloud, Monday morning)
           reads the status, release notes, deprecations and CoreELEC news,
           runs the test suite, updates COMPATIBILITY.md, fixes code if needed
                 │  pushes a branch auto/<date>-<topic>  (never main)
                 ▼
           GitHub Action "auto-pr" opens a pull request
                 │  the "test" workflow has already run on the branch
                 ▼
 you       review and merge; test on hardware when the script changed
```

### What the daily check covers

[`.github/scripts/upstream-check.sh`](.github/scripts/upstream-check.sh) checks four things:

1. the latest versions can be determined;
2. the aarch64 static tarball exists and contains every binary the script copies and tests, and any new files are reported;
3. the `daemon.json` the script writes, both with and without `MIN_API_VERSION`, is accepted by `dockerd --validate` of that exact version (the x86_64 build, since validation does not depend on the CPU);
4. the Compose and Buildx aarch64 assets and their checksums exist.

The results are kept on the `upstream-status` branch: `status.json`, `summary.md`, and `history.csv` with one line per day.

### What the weekly review covers

Things a script cannot judge:

- Docker release notes and deprecations since the last reviewed version, looking for changes to:
  - the default `daemon.json` keys;
  - options found in tamusiunas or add-on configs;
  - the minimum API version;
  - cgroup v1 and old kernels (CoreELEC boxes run 4.9–5.15);
  - storage drivers and the containerd image store;
  - iptables and nftables;
  - systemd behaviour;
- Compose and Buildx release notes, for changes to asset names or checksum files;
- CoreELEC announcements, for releases that change the Kodi Docker add-on (paths, unit name, `docker.conf`) or the userspace architecture.

The outcome is always a new row in [COMPATIBILITY.md](COMPATIBILITY.md) and an updated `.github/reviewed-versions`. When something breaks, a fix with tests, a `TOOL_VERSION` bump and a CHANGELOG entry are added too. If nothing changed upstream, the task does nothing.

## One-time setup

- **Settings → Actions → General → Workflow permissions** (the last block on the page): tick *Allow GitHub Actions to create and approve pull requests* and save. Without it, `auto-pr` cannot open pull requests. The default token permission can stay *read*: each workflow asks for the extra rights it needs.
- **Watch the repository** (at least *Issues* and *Pull requests*) to get notified.

## Reviewing an automatic pull request

1. Check that the **test** workflow on the branch is green.
2. Read the COMPATIBILITY.md row: does anything break?
3. If `docker-coreelec.sh` changed, test it on a real box before merging. Use `status`, then `install`, then `rollback`.
4. Merge.

## Releasing

1. Make sure `TOOL_VERSION` in `docker-coreelec.sh` and the top entry in `CHANGELOG.md` match.
2. Tag and push: `git tag v1.0.1 && git push origin v1.0.1`.
3. Optionally create a GitHub release from the tag, with the CHANGELOG entry as notes.

Users get the new script with `docker-coreelec self-update`.

## If the automation stops

- `upstream-status` not updated for days: check the *Actions* tab. Scheduled workflows are paused after 60 days without repository activity, and can be re-enabled there.
- No weekly pull requests or reports: check the scheduled task in Claude.
- Everything can be done by hand too: run the check script locally, read the release notes, and follow *What the weekly review covers*.
