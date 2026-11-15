#!/bin/sh
# Usage: sh build-jar.sh PEX_JAR JDBC_JAR /absolute/output-directory
set -eu
if [ "$#" -ne 3 ]; then
    echo "Usage: sh build-jar.sh PEX_JAR JDBC_JAR /absolute/output-directory" >&2
    exit 2
fi
for dep in "$1" "$2"; do
    if [ ! -f "$dep" ] || [ ! -r "$dep" ]; then
        echo "Required SDK jar not readable: $dep" >&2
        exit 2
    fi
done
case "$3" in /*) ;; *) echo "Use an absolute output directory" >&2; exit 2;; esac
root=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
mkdir -p "$3"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
javac --release 11 -cp "$1:$2" -d "$tmp" "$root"/java/storm/pex/*.java
jar --create --file "$3/storm-safe-handoff.jar" -C "$tmp" storm
sha256sum "$3/storm-safe-handoff.jar"
