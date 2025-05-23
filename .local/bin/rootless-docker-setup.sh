#!/usr/bin/env bash

# This file was created by running the following command with few modifications to suit CloudShell use case:
# curl -L -o rootless-docker-setup.sh https://get.docker.com/rootless
set -x
set -e

# Docker CE for Linux installation script (Rootless mode)
#
# See https://docs.docker.com/go/rootless/ for the
# installation steps.
#
# This script is meant for quick & easy install via:
#   $ curl -fsSL https://get.docker.com/rootless -o get-docker.sh
#   $ sh get-docker.sh
#
# NOTE: Make sure to verify the contents of the script
#       you downloaded matches the contents of install.sh
#       located at https://github.com/docker/docker-install
#       before executing.
#
# Git commit from https://github.com/docker/docker-install when
# the script was uploaded (Should only be modified by upload job):

# This script should be run with an unprivileged user and install/setup Docker under $HOME/bin/.

init_vars() {
	BIN="$HOME/.local/bin"

	DAEMON=dockerd
	SYSTEMD=
	if systemctl --user daemon-reload >/dev/null 2>&1; then
		SYSTEMD=1
	fi
}

checks() {
	# HOME verification
	if [ ! -d "$HOME" ]; then
		echo >&2 "Aborting because HOME directory $HOME does not exist"
		exit 1
	fi

	if [ -d "$BIN" ]; then
		if [ ! -w "$BIN" ]; then
			echo >&2 "Aborting because $BIN is not writable"
			exit 1
		fi
	else
		if [ ! -w "$HOME" ]; then
			echo >&2 "Aborting because HOME (\"$HOME\") is not writable"
			exit 1
		fi
	fi

	# Validate XDG_RUNTIME_DIR
	if [ ! -w "$XDG_RUNTIME_DIR" ]; then
		echo >&2 "Aborting because XDG_RUNTIME_DIR (\"$XDG_RUNTIME_DIR\") does not exist or is not writable"
	fi
	INSTRUCTIONS=

	# ip_tables module dependency check
	if [ -z "$SKIP_IPTABLES" ] && ! lsmod | grep ip_tables >/dev/null 2>&1 && ! grep -q ip_tables "/lib/modules/$(uname -r)/modules.builtin"; then
		INSTRUCTIONS="${INSTRUCTIONS}
modprobe ip_tables"
	fi

	# debian requires setting unprivileged_userns_clone
	if [ -f /proc/sys/kernel/unprivileged_userns_clone ]; then
		if [ "1" != "$(cat /proc/sys/kernel/unprivileged_userns_clone)" ]; then
			INSTRUCTIONS="${INSTRUCTIONS}
cat <<EOT > /etc/sysctl.d/50-rootless.conf
kernel.unprivileged_userns_clone = 1
EOT
sysctl --system"
		fi
	fi

	# centos requires setting max_user_namespaces
	if [ -f /proc/sys/user/max_user_namespaces ]; then
		if [ "0" = "$(cat /proc/sys/user/max_user_namespaces)" ]; then
			INSTRUCTIONS="${INSTRUCTIONS}
cat <<EOT > /etc/sysctl.d/51-rootless.conf
user.max_user_namespaces = 28633
EOT
sysctl --system"
		fi
	fi

	if [ -n "$INSTRUCTIONS" ]; then
		echo "# Missing system requirements. Please run following commands to
# install the requirements and run this installer again.
# Alternatively iptables checks can be disabled with SKIP_IPTABLES=1"

		echo
		echo "cat <<EOF | sudo sh -x"
		echo "$INSTRUCTIONS"
		echo "EOF"
		echo
		exit 1
	fi

	# validate subuid/subgid files for current user
	if ! grep "^$(id -un):\|^$(id -u):" /etc/subuid >/dev/null 2>&1; then
		echo >&2 "Could not find records for the current user $(id -un) from /etc/subuid . Please make sure valid subuid range is set there.
For example:
echo \"$(id -un):100000:65536\" >> /etc/subuid"
		exit 1
	fi
	if ! grep "^$(id -un):\|^$(id -u):" /etc/subgid >/dev/null 2>&1; then
		echo >&2 "Could not find records for the current user $(id -un) from /etc/subgid . Please make sure valid subuid range is set there.
For example:
echo \"$(id -un):100000:65536\" >> /etc/subgid"
		exit 1
	fi
}

exec_setuptool() {
	if [ -n "$FORCE_ROOTLESS_INSTALL" ]; then
		set -- "$@" --force
	fi
	if [ -n "$SKIP_IPTABLES" ]; then
		set -- "$@" --skip-iptables
	fi
	(
		set -x
		PATH="$BIN:$PATH" "$BIN/dockerd-rootless-setuptool.sh" install "$@"
	)
}

do_install() {
	init_vars
	checks

	exec_setuptool "$@"
}

do_install "$@"
