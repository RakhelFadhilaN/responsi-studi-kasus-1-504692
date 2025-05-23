#!/usr/bin/env bash

set -euo pipefail
set -x

export USER="$1"
export HOME="/home/${USER}"
export SKIP_IPTABLES=1

# Path to the XDG_RUNTIME_DIR should be writable by the user, ideally this
# should be under user's home directory.
export XDG_RUNTIME_DIR=$HOME/.docker/run
export DOCKER_HOST=unix://$HOME/.docker/run/docker.sock
export PATH=$HOME/.local/bin:$PATH
export DOCKER_LOGS=$HOME/.docker/logs

setpriv --clear-groups --reuid 9527 --regid 9527 \
    --inh-caps -all,+setuid,+setgid --bounding-set -all,+setuid,+setgid \
    rootless-docker-setup.sh >>$DOCKER_LOGS 2>&1

# TODO: Once the ACI kernel + Azure Linux 3.0 combination has support for iptables, change the flags to:
# CONDITIONAL_FLAGS="--iptables=true"
CONDITIONAL_FLAGS="--iptables=false --bridge=none"
setpriv --clear-groups --reuid 9527 --regid 9527 \
    --inh-caps -all,+setuid,+setgid --bounding-set -all,+setuid,+setgid \
    dockerd-rootless.sh $CONDITIONAL_FLAGS --ip6tables=false --storage-driver=fuse-overlayfs >>$DOCKER_LOGS 2>&1 &
