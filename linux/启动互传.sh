#!/bin/sh
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
chmod +x "$DIR/huchuan" 2>/dev/null
exec "$DIR/huchuan"
