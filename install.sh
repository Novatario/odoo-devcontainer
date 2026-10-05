#!/usr/bin/env bash
#
# Install Odoo 19 Community from source, with PostgreSQL, on Ubuntu 24.04.
#
# One script, two callers:
#   - the Dockerfile in this repo, which bakes the result into the image
#   - the setup script of a Claude Code cloud environment, which runs it
#     straight from GitHub:
#
#       curl -fsSL https://raw.githubusercontent.com/Novatario/odoo-devcontainer/main/install.sh \
#         | bash -s -- --user root
#
# Both end up with the same layout, so a repo's tooling never has to ask where
# it is running:
#
#   /opt/odoo/19.0            Odoo source (git, shallow), the commit in ODOO_COMMIT
#   /opt/odoo/venv            Python virtualenv with Odoo's requirements
#   /opt/pw-browsers          Playwright's Chromium
#
# Options:
#   --user NAME     the OS user that runs Odoo: owns the venv and gets a
#                   PostgreSQL superuser role of the same name, so peer auth
#                   works without a password (default: the calling user)
#   --commit SHA    Odoo commit to check out (default: newest commit of 19.0)
#
# Must run as root. Safe to run again: every step checks before it acts.
#
set -euo pipefail

ODOO_VERSION=19.0
ODOO_REPO=https://github.com/odoo/odoo.git
ODOO_ROOT=/opt/odoo
ODOO_HOME="$ODOO_ROOT/$ODOO_VERSION"
VENV="$ODOO_ROOT/venv"
# 3.12 is Ubuntu 24.04's own Python. Named explicitly because some images
# (the Claude Code cloud sandbox among them) point python3 at another version.
PYTHON=python3.12
export PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers

RUN_USER="${SUDO_USER:-$(id -un)}"
ODOO_COMMIT=""

while (( $# )); do
    case "$1" in
        --user)   RUN_USER="$2"; shift 2 ;;
        --commit) ODOO_COMMIT="$2"; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

note() { printf '\033[36m==>\033[0m %s\n' "$*"; }

[[ "$(id -u)" == 0 ]] || { echo "install.sh must run as root" >&2; exit 1; }
id "$RUN_USER" >/dev/null 2>&1 || { echo "user '$RUN_USER' does not exist" >&2; exit 1; }

# --- System packages ---------------------------------------------------------
# Build tools and headers are kept on purpose: psycopg2 and python-ldap have
# no wheels, and an addon's own dependencies may need a compiler later too.
note "installing system packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q --no-install-recommends \
    ca-certificates curl git sudo less \
    build-essential "$PYTHON" "$PYTHON"-venv "$PYTHON"-dev \
    libpq-dev libldap2-dev libsasl2-dev libxml2-dev libxslt1-dev \
    libjpeg-dev zlib1g-dev libffi-dev \
    postgresql postgresql-client
rm -rf /var/lib/apt/lists/*

# --- Odoo source -------------------------------------------------------------
if [[ -z "$ODOO_COMMIT" ]]; then
    ODOO_COMMIT="$(git ls-remote "$ODOO_REPO" "refs/heads/$ODOO_VERSION" | cut -f1)"
fi
[[ -n "$ODOO_COMMIT" ]] || { echo "could not resolve the newest commit of $ODOO_VERSION" >&2; exit 1; }

if [[ "$(git -C "$ODOO_HOME" rev-parse HEAD 2>/dev/null || true)" == "$ODOO_COMMIT" ]]; then
    note "odoo source already at $ODOO_COMMIT"
else
    note "fetching odoo $ODOO_VERSION at $ODOO_COMMIT"
    mkdir -p "$ODOO_HOME"
    git -C "$ODOO_HOME" init -q
    git -C "$ODOO_HOME" remote remove origin 2>/dev/null || true
    git -C "$ODOO_HOME" remote add origin "$ODOO_REPO"
    git -C "$ODOO_HOME" fetch -q --depth 1 origin "$ODOO_COMMIT"
    git -C "$ODOO_HOME" checkout -q --force FETCH_HEAD
fi
# Owned by root, read by the run user: without this, git refuses the checkout
# ("dubious ownership") and Odoo cannot report its own commit.
git config --system --get-all safe.directory 2>/dev/null | grep -qxF "$ODOO_HOME" \
    || git config --system --add safe.directory "$ODOO_HOME"

# --- Python ------------------------------------------------------------------
# Odoo's requirements.txt pins a version per Python version, so a plain pip
# install gets exactly what Odoo was tested with.
#   debugpy  - bin/odoo start --debug, which F5 in VS Code attaches to
#   inotify  - makes dev_mode=reload work; Odoo imports it optionally
#   playwright - installs the Chromium below and drives it
note "installing python requirements into $VENV"
[[ -x "$VENV/bin/python" ]] || "$PYTHON" -m venv "$VENV"
"$VENV/bin/pip" install -q --upgrade pip wheel
"$VENV/bin/pip" install -q -r "$ODOO_HOME/requirements.txt"
"$VENV/bin/pip" install -q debugpy inotify playwright

note "installing chromium for playwright"
"$VENV/bin/playwright" install --with-deps chromium
rm -rf /var/lib/apt/lists/*

chown -R "$RUN_USER": "$VENV"
chmod -R a+rX "$PLAYWRIGHT_BROWSERS_PATH"

# --- PostgreSQL --------------------------------------------------------------
# No systemd in a container: pg_ctlcluster starts it, here and at every
# container start (the consuming repo's tooling does that). The port is pinned
# because the cluster takes the next free one if 5432 happens to be in use
# while it is created.
PG_VERSION="$(ls /etc/postgresql | sort -V | tail -1)"
pg_conftool "$PG_VERSION" main set port 5432
note "starting postgresql $PG_VERSION"
pg_isready -q || pg_ctlcluster "$PG_VERSION" main start
for _ in $(seq 1 20); do pg_isready -q && break; sleep 0.5; done
pg_isready -q || { echo "postgresql did not start" >&2; exit 1; }

if ! su postgres -c "psql -tAc \"select 1 from pg_roles where rolname = '$RUN_USER'\"" | grep -q 1; then
    note "creating postgresql role '$RUN_USER'"
    su postgres -c "createuser --superuser '$RUN_USER'"
fi

# The user may start postgresql again after a container restart without a
# password prompt, and nothing else.
if [[ "$RUN_USER" != root ]]; then
    echo "$RUN_USER ALL=(root) NOPASSWD: /usr/bin/pg_ctlcluster" > /etc/sudoers.d/odoo-postgres
    chmod 0440 /etc/sudoers.d/odoo-postgres
fi

# Stopped cleanly, so an image never carries a stale pid. Whoever needs it
# next starts it.
pg_ctlcluster "$PG_VERSION" main stop

echo "$ODOO_COMMIT" > "$ODOO_ROOT/COMMIT"
note "odoo $ODOO_VERSION ready: $ODOO_HOME at $ODOO_COMMIT, python $VENV"
