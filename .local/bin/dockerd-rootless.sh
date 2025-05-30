#!/usr/bin/env bash

# cd compute-CloudShell/src/images/agent/linux/rootless-docker
# curl -LO https://raw.githubusercontent.com/moby/moby/refs/tags/v27.3.1/contrib/dockerd-rootless.sh
# chmod +x ./dockerd-rootless.sh

# dockerd-rootless.sh executes dockerd in rootless mode.
#
# Usage: dockerd-rootless.sh [DOCKERD_OPTIONS]
#
# External dependencies:
# * newuidmap and newgidmap needs to be installed.
# * /etc/subuid and /etc/subgid needs to be configured for the current user.
# * Either one of slirp4netns (>= v0.4.0), VPNKit, lxc-user-nic needs to be installed.
#
# Recognized environment variables:
# * DOCKERD_ROOTLESS_ROOTLESSKIT_STATE_DIR=DIR: the rootlesskit state dir. Defaults to "$XDG_RUNTIME_DIR/dockerd-rootless".
# * DOCKERD_ROOTLESS_ROOTLESSKIT_NET=(slirp4netns|vpnkit|pasta|lxc-user-nic): the rootlesskit network driver. Defaults to "slirp4netns" if slirp4netns (>= v0.4.0) is installed. Otherwise defaults to "vpnkit".
# * DOCKERD_ROOTLESS_ROOTLESSKIT_MTU=NUM: the MTU value for the rootlesskit network driver. Defaults to 65520 for slirp4netns, 1500 for other drivers.
# * DOCKERD_ROOTLESS_ROOTLESSKIT_PORT_DRIVER=(builtin|slirp4netns|implicit): the rootlesskit port driver. Defaults to "builtin".
# * DOCKERD_ROOTLESS_ROOTLESSKIT_SLIRP4NETNS_SANDBOX=(auto|true|false): whether to protect slirp4netns with a dedicated mount namespace. Defaults to "auto".
# * DOCKERD_ROOTLESS_ROOTLESSKIT_SLIRP4NETNS_SECCOMP=(auto|true|false): whether to protect slirp4netns with seccomp. Defaults to "auto".
# * DOCKERD_ROOTLESS_ROOTLESSKIT_DISABLE_HOST_LOOPBACK=(true|false): prohibit connections to 127.0.0.1 on the host (including via 10.0.2.2, in the case of slirp4netns). Defaults to "true".

# To apply an environment variable via systemd, create ~/.config/systemd/user/docker.service.d/override.conf as follows,
# and run `systemctl --user daemon-reload && systemctl --user restart docker`:
# --- BEGIN ---
# [Service]
# Environment="DOCKERD_ROOTLESS_ROOTLESSKIT_NET=pasta"
# Environment="DOCKERD_ROOTLESS_ROOTLESSKIT_PORT_DRIVER=implicit"
# ---  END  ---

# Guide to choose the network driver and the port driver:
#
#  Network driver | Port driver    | Net throughput | Port throughput | Src IP | No SUID | Note
#  ---------------|----------------|----------------|-----------------|--------|---------|---------------------------------------------------------
#  slirp4netns    | builtin        | Slow           | Fast ✅         | ❌     | ✅      | Default in typical setup
#  vpnkit         | builtin        | Slow           | Fast ✅         | ❌     | ✅      | Default when slirp4netns is not installed
#  slirp4netns    | slirp4netns    | Slow           | Slow            | ✅     | ✅      |
#  pasta          | implicit       | Slow           | Fast ✅         | ✅     | ✅      | Experimental; Needs recent version of pasta (2023_12_04)
#  lxc-user-nic   | builtin        | Fast ✅        | Fast ✅         | ❌     | ❌      | Experimental
#  (bypass4netns) | (bypass4netns) | Fast ✅        | Fast ✅         | ✅     | ✅      | (Not integrated to RootlessKit)

# See the documentation for the further information: https://docs.docker.com/go/rootless/

set -e -x
case "$1" in
	"check" | "install" | "uninstall")
		echo "Did you mean 'dockerd-rootless-setuptool.sh $@' ?"
		exit 1
		;;
esac
if ! [ -w "$XDG_RUNTIME_DIR" ]; then
	echo "XDG_RUNTIME_DIR needs to be set and writable"
	exit 1
fi
if ! [ -d "$HOME" ]; then
	echo "HOME needs to be set and exist."
	exit 1
fi

rootlesskit=""
for f in docker-rootlesskit rootlesskit; do
	if command -v $f > /dev/null 2>&1; then
		rootlesskit=$f
		break
	fi
done
if [ -z "$rootlesskit" ]; then
	echo "rootlesskit needs to be installed"
	exit 1
fi

: "${DOCKERD_ROOTLESS_ROOTLESSKIT_STATE_DIR:=$XDG_RUNTIME_DIR/dockerd-rootless}"
: "${DOCKERD_ROOTLESS_ROOTLESSKIT_NET:=}"
: "${DOCKERD_ROOTLESS_ROOTLESSKIT_MTU:=}"
: "${DOCKERD_ROOTLESS_ROOTLESSKIT_PORT_DRIVER:=builtin}"
: "${DOCKERD_ROOTLESS_ROOTLESSKIT_SLIRP4NETNS_SANDBOX:=auto}"
: "${DOCKERD_ROOTLESS_ROOTLESSKIT_SLIRP4NETNS_SECCOMP:=auto}"
: "${DOCKERD_ROOTLESS_ROOTLESSKIT_DISABLE_HOST_LOOPBACK:=}"
net=$DOCKERD_ROOTLESS_ROOTLESSKIT_NET
mtu=$DOCKERD_ROOTLESS_ROOTLESSKIT_MTU
if [ -z "$net" ]; then
	if command -v slirp4netns > /dev/null 2>&1; then
		# If --netns-type is present in --help, slirp4netns is >= v0.4.0.
		if slirp4netns --help | grep -qw -- --netns-type; then
			net=slirp4netns
			if [ -z "$mtu" ]; then
				mtu=65520
			fi
		else
			echo "slirp4netns found but seems older than v0.4.0. Falling back to VPNKit."
		fi
	fi
	if [ -z "$net" ]; then
		if command -v vpnkit > /dev/null 2>&1; then
			net=vpnkit
		else
			echo "Either slirp4netns (>= v0.4.0) or vpnkit needs to be installed"
			exit 1
		fi
	fi
fi
if [ -z "$mtu" ]; then
	mtu=1500
fi

host_loopback="--disable-host-loopback"
if [ "$DOCKERD_ROOTLESS_ROOTLESSKIT_DISABLE_HOST_LOOPBACK" = "false" ]; then
	host_loopback=""
fi

dockerd="${DOCKERD:-dockerd}"

if [ -z "$_DOCKERD_ROOTLESS_CHILD" ]; then
	_DOCKERD_ROOTLESS_CHILD=1
	export _DOCKERD_ROOTLESS_CHILD
	if [ "$(id -u)" = "0" ]; then
		echo "This script must be executed as a non-privileged user"
		exit 1
	fi
	# `selinuxenabled` always returns false in RootlessKit child, so we execute `selinuxenabled` in the parent.
	# https://github.com/rootless-containers/rootlesskit/issues/94
	if command -v selinuxenabled > /dev/null 2>&1 && selinuxenabled; then
		_DOCKERD_ROOTLESS_SELINUX=1
		export _DOCKERD_ROOTLESS_SELINUX
	fi
	# Re-exec the script via RootlessKit, so as to create unprivileged {user,mount,network} namespaces.
	#
	# --copy-up allows removing/creating files in the directories by creating tmpfs and symlinks
	# * /etc: copy-up is required so as to prevent `/etc/resolv.conf` in the
	#         namespace from being unexpectedly unmounted when `/etc/resolv.conf` is recreated on the host
	#         (by either systemd-networkd or NetworkManager)
	# * /run: copy-up is required so that we can create /run/docker (hardcoded for plugins) in our namespace
	exec $rootlesskit \
		--state-dir=$DOCKERD_ROOTLESS_ROOTLESSKIT_STATE_DIR \
		--net=$net --mtu=$mtu \
		--slirp4netns-sandbox=$DOCKERD_ROOTLESS_ROOTLESSKIT_SLIRP4NETNS_SANDBOX \
		--slirp4netns-seccomp=$DOCKERD_ROOTLESS_ROOTLESSKIT_SLIRP4NETNS_SECCOMP \
		$host_loopback --port-driver=$DOCKERD_ROOTLESS_ROOTLESSKIT_PORT_DRIVER \
		--copy-up=/etc --copy-up=/run \
		--propagation=rslave \
		$DOCKERD_ROOTLESS_ROOTLESSKIT_FLAGS \
		"$0" "$@"
else
	[ "$_DOCKERD_ROOTLESS_CHILD" = 1 ]
	# remove the symlinks for the existing files in the parent namespace if any,
	# so that we can create our own files in our mount namespace.
	rm -f /run/docker /run/containerd /run/xtables.lock

	if [ -n "$_DOCKERD_ROOTLESS_SELINUX" ]; then
		# iptables requires /run in the child to be relabeled. The actual /run in the parent is unaffected.
		# https://github.com/containers/podman/blob/e6fc34b71aa9d876b1218efe90e14f8b912b0603/libpod/networking_linux.go#L396-L401
		# https://github.com/moby/moby/issues/41230
		chcon system_u:object_r:iptables_var_run_t:s0 /run
	fi

	if [ "$(stat -c %T -f /etc)" = "tmpfs" ] && [ -L "/etc/ssl" ]; then
		# Workaround for "x509: certificate signed by unknown authority" on openSUSE Tumbleweed.
		# https://github.com/rootless-containers/rootlesskit/issues/225
		realpath_etc_ssl=$(realpath /etc/ssl)
		rm -f /etc/ssl
		mkdir /etc/ssl
		mount --rbind ${realpath_etc_ssl} /etc/ssl
	fi

	exec "$dockerd" "$@"
fi
