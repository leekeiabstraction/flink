#!/usr/bin/env bash
# Stage the extra JARs into /opt/flink/lib before the official entrypoint
# runs. We can't write the bind-mounted /opt/flink/lib directly without
# masking the image's bundled JARs, so we cp from a side directory.
set -e
if [[ -d /opt/flink/lib-extra ]]; then
    cp -n /opt/flink/lib-extra/*.jar /opt/flink/lib/ 2>/dev/null || true
fi
exec /docker-entrypoint.sh "$@"
