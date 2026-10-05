#!/usr/bin/env bash
#
# Start Odoo once and check that it answers. Runs inside the image (the nightly
# build calls it before publishing) or anywhere install.sh has run.
#
#   docker run --rm <image> bash -s < test/smoke.sh
#
set -euo pipefail

ODOO_HOME="${ODOO_HOME:-/opt/odoo/19.0}"
PY="${ODOO_VENV:-/opt/odoo/venv}/bin/python"
DB="smoke_$$"
DATA="$(mktemp -d)"
LOG="$DATA/odoo.log"
PORT=8069

if ! pg_isready -q; then
    version="$(ls /etc/postgresql | sort -V | tail -1)"
    if [[ "$(id -u)" == 0 ]]; then pg_ctlcluster "$version" main start
    else sudo -n pg_ctlcluster "$version" main start; fi
fi
for _ in $(seq 1 20); do pg_isready -q && break; sleep 0.5; done
pg_isready -q || { echo "smoke test FAILED: postgresql did not start" >&2; exit 1; }

cleanup() {
    [[ -n "${PID:-}" ]] && kill "$PID" 2>/dev/null || true
    dropdb --if-exists "$DB" 2>/dev/null || true
    rm -rf "$DATA"
}
trap cleanup EXIT

echo "==> odoo $(git -C "$ODOO_HOME" rev-parse --short HEAD): installing base and web into $DB"
"$PY" "$ODOO_HOME/odoo-bin" -d "$DB" --data-dir "$DATA" -i base,web \
    --stop-after-init --log-level warn

echo "==> starting the server"
"$PY" "$ODOO_HOME/odoo-bin" -d "$DB" --data-dir "$DATA" --http-interface 127.0.0.1 --http-port "$PORT" \
    --db-filter "^$DB\$" > "$LOG" 2>&1 &
PID=$!

for _ in $(seq 1 60); do
    if curl -sf -o /dev/null "http://127.0.0.1:$PORT/web/login"; then
        echo "==> /web/login answers: smoke test passed"
        exit 0
    fi
    kill -0 "$PID" 2>/dev/null || break
    sleep 1
done

echo "smoke test FAILED: the server did not answer on /web/login" >&2
tail -50 "$LOG" >&2
exit 1
