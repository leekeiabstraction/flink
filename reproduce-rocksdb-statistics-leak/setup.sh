#!/usr/bin/env bash
# Download the JARs the OSS Flink image doesn't bundle but the repro needs:
#   - flink-statebackend-rocksdb       (RocksDB state backend wrapper)
#   - frocksdbjni                      (native RocksDB JNI library)
#
# Override versions via env var if you bump the cluster image.
set -euo pipefail
cd "$(dirname "$0")"

ROCKSDB_BACKEND_VERSION="${ROCKSDB_BACKEND_VERSION:-2.2.1}"
FROCKSDBJNI_VERSION="${FROCKSDBJNI_VERSION:-8.10.0-ververica-1.0}"

mkdir -p lib

fetch() {
    local url="$1"
    local out="lib/$(basename "$url")"
    if [[ -f "$out" ]]; then
        echo "[skip] $out"
    else
        echo "[fetch] $url"
        curl -sf -o "$out" "$url"
    fi
}

fetch "https://repo1.maven.org/maven2/org/apache/flink/flink-statebackend-rocksdb/${ROCKSDB_BACKEND_VERSION}/flink-statebackend-rocksdb-${ROCKSDB_BACKEND_VERSION}.jar"
fetch "https://repo1.maven.org/maven2/com/ververica/frocksdbjni/${FROCKSDBJNI_VERSION}/frocksdbjni-${FROCKSDBJNI_VERSION}.jar"

echo
echo "Contents of lib/:"
ls -lh lib/
