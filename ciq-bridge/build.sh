#!/bin/sh
# Build for the Garmin Edge MTB (see README "Building the Connect IQ apps").
# CIQ_SDK: Connect IQ SDK dir; CIQ_KEY: your developer key (.der).
# Defaults point to a local ../tools/ folder, which is not part of the repo.
set -e
cd "$(dirname "$0")"
SDK="${CIQ_SDK:-../tools/ciq-sdk}"
KEY="${CIQ_KEY:-../tools/developer_key.der}"
if [ -d ../tools/jre ]; then
    export JAVA_HOME="$PWD/../tools/jre" PATH="$PWD/../tools/jre/bin:$PATH"
fi
mkdir -p bin
"$SDK/bin/monkeyc" -f monkey.jungle -d edgemtb -y "$KEY" -o bin/EclipsBridge.prg -w "$@"
