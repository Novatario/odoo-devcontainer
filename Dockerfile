# Odoo 19 Community from source, with PostgreSQL inside, for development.
# Everything happens in install.sh, which the Claude Code cloud sandbox runs
# too: this file only decides the base and the user.
FROM ubuntu:24.04

# Pass a commit to rebuild a known one; the nightly build passes the newest.
ARG ODOO_COMMIT=""

ENV ODOO_HOME=/opt/odoo/19.0 \
    ODOO_VENV=/opt/odoo/venv \
    PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers \
    LANG=C.UTF-8

COPY install.sh /tmp/install.sh
# ubuntu:24.04 ships the user 'ubuntu' (uid 1000); devcontainer.json runs as it.
RUN bash /tmp/install.sh --user ubuntu ${ODOO_COMMIT:+--commit "$ODOO_COMMIT"} \
    && rm /tmp/install.sh

LABEL org.opencontainers.image.source="https://github.com/Novatario/odoo-devcontainer" \
      org.opencontainers.image.description="Odoo 19 Community from source, with PostgreSQL, for development" \
      org.opencontainers.image.licenses="LGPL-3.0"

USER ubuntu
WORKDIR /home/ubuntu
CMD ["sleep", "infinity"]
