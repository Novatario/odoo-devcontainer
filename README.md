# odoo-devcontainer

The development environment for Novatar's Odoo 19 work: **Odoo 19 Community from source, with PostgreSQL, in one container.** Public on purpose: it holds nothing secret and nothing Novatar-specific. The addons and the configuration that uses this image live in the private `odoo-custom-addons` repo.

## What is in it

| Path | What |
|---|---|
| `/opt/odoo/19.0` | Odoo 19 Community source, a shallow git checkout |
| `/opt/odoo/COMMIT` | the Odoo commit it was built from |
| `/opt/odoo/venv` | Python 3.12 with Odoo's `requirements.txt`, plus `debugpy`, `inotify` and `playwright` |
| `/opt/pw-browsers` | Playwright's Chromium |
| PostgreSQL 16 | with a superuser role for the user `ubuntu`, reached over the unix socket (peer auth) |

There is no systemd, so nothing starts PostgreSQL by itself: the user `ubuntu` may run `sudo pg_ctlcluster` without a password, and the consuming repo does that at every container start. Odoo Enterprise is never in the image.

## One install script, two uses

[`install.sh`](install.sh) does all of the above on Ubuntu 24.04.

- The [`Dockerfile`](Dockerfile) runs it to build the image.
- A Claude Code cloud environment runs it as its setup script, so the sandbox gets the same layout:

  ```bash
  curl -fsSL https://raw.githubusercontent.com/Novatario/odoo-devcontainer/main/install.sh | bash -s -- --user root
  ```

Options: `--user NAME` (the OS user that runs Odoo; default the caller) and `--commit SHA` (default the newest commit of 19.0). It is safe to run again.

## Image and updates

[`.github/workflows/build.yml`](.github/workflows/build.yml) builds the image every night from the newest commit of Odoo's 19.0 branch, and on every push to `main`. [`test/smoke.sh`](test/smoke.sh) then starts Odoo in it once and checks that `/web/login` answers. Only an image that passed is published:

- `ghcr.io/novatario/odoo-devcontainer:19.0`, the tag dev containers follow
- `ghcr.io/novatario/odoo-devcontainer:19.0-<yyyymmdd>-<odoo commit>`, kept to go back to

A failing night leaves `19.0` on the last good image. Production does not use this image; it pins a tested Odoo commit of its own.

## Test locally

```bash
docker build -t odoo-devcontainer:test .
docker run --rm odoo-devcontainer:test bash -s < test/smoke.sh
```
