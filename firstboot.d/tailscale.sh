#!/bin/sh
# Add support for EdgeOS 3.0+ on ER-X routers

set -e

version="3.0"

sed -i 's|^mozilla\/DST_Root_CA_X3\.crt|!mozilla/DST_Root_CA_X3.crt|' /etc/ca-certificates.conf
update-ca-certificates --fresh

# Install Tailscale Repository
source /opt/vyatta/etc/functions/script-template
# Check if repository is already installed
installed=$(run show configuration commands | grep -c 'set system package repository tailscale')

if [ ${installed} -lt "3" ]; then
	echo "Installing Tailscale Repository..."
	configure
	set system package repository tailscale url '[signed-by=/usr/share/keyrings/tailscale-stretch-stable.gpg] https://pkgs.tailscale.com/stable/debian'
	set system package repository tailscale distribution stretch
	set system package repository tailscale components main
	commit comment "Add Tailscale repository"
	save
fi

mkdir -p /config/tailscale/systemd/tailscaled.service.d
mkdir -p /config/tailscale/state

# Create a bind mount for the Tailscale state directory
if [ ! -f /config/tailscale/systemd/var-lib-tailscale.mount ]; then
	cat > /config/tailscale/systemd/var-lib-tailscale.mount <<-EOF
[Mount]
What=/config/tailscale/state
Where=/var/lib/tailscale
Type=none
Options=bind

[Install]
WantedBy=multi-user.target
	EOF
fi

# Add an override to tailscaled.service to require the bind mount
if [ ! -f /config/tailscale/systemd/tailscaled.service.d/mount.conf ]; then
	cat > /config/tailscale/systemd/tailscaled.service.d/mount.conf <<-EOF
[Unit]
RequiresMountsFor=/var/lib/tailscale
	EOF
fi
# Add an override to tailscaled.service to wait until "UBNT Routing Daemons"
# has finished, otherwise tailscaled won't have proper networking
if [ ! -f /config/tailscale/systemd/tailscaled.service.d/wait-for-networking.conf ]; then
	cat > /config/tailscale/systemd/tailscaled.service.d/wait-for-networking.conf <<-EOF
[Unit]
Wants=vyatta-router.service
After=vyatta-router.service
	EOF
fi

if [ ! -L /etc/systemd/system/tailscaled.service.d ]; then
	ln -s /config/tailscale/systemd/tailscaled.service.d /etc/systemd/system/tailscaled.service.d
fi
systemctl daemon-reload

# Ensure there is a post-config script to install Tailscale
mkdir -p /config/scripts/post-config.d
cat > /config/scripts/post-config.d/tailscale.sh <<EOF
#!/bin/sh

set -e

version="${version}"

reload=""

# The mount unit needs to be copied rather than linked.
# systemd errors with "Link has been severed" if the unit is a symlink.
if [ ! -f /etc/systemd/system/var-lib-tailscale.mount ]; then
	echo Installing /var/lib/tailscale mount unit
	cp /config/tailscale/systemd/var-lib-tailscale.mount /etc/systemd/system/var-lib-tailscale.mount
	reload=y
fi

if [ ! -L /etc/systemd/system/tailscaled.service.d ]; then
	ln -s /config/tailscale/systemd/tailscaled.service.d /etc/systemd/system/tailscaled.service.d
	reload=y
fi

if [ -n "\$reload" ]; then
	# Ensure systemd has loaded the unit overrides
	systemctl daemon-reload
fi

KEYRING=/usr/share/keyrings/tailscale-stretch-stable.gpg

if ! gpg --list-keys --with-colons --keyring \$KEYRING 2>/dev/null | grep -qF info@tailscale.com; then
	echo Installing Tailscale repository signing key
	if [ ! -e /config/tailscale/stretch.gpg ]; then
		curl -fsSL https://pkgs.tailscale.com/stable/debian/stretch.asc | gpg --dearmor > /config/tailscale/stretch.gpg
	fi
	cp /config/tailscale/stretch.gpg \$KEYRING
fi

pkg_status=\$(dpkg-query -Wf '\${Status}' tailscale 2>/dev/null || true)
if ! echo \$pkg_status| grep -qF "install ok installed"; then
	# Sometimes after a firmware upgrade the package goes into half-configured state
	if echo \$pkg_status | grep -qF "half-configured"; then
		# Use systemd-run to configure the package in a separate unit, otherwise it will block
		# due to tailscaled.service waiting on vyatta-router.service, which is running this script.
		systemd-run --no-block dpkg --configure -a
	else
		echo "Installing Tailscale"
		# Clear storage space to allow installation on ER-X
		# remove old tailscale packages if they exist
		rm -f /config/data/firstboot/install-packages/tailscale*.deb
		# cleanup apt packages to save space
		apt -qy clean
		# remove backup system image
		# executes the 'delete system image' command and pipes 'yes' to it for confirmation
		yes | /opt/vyatta/bin/vyatta-op-cmd-wrapper delete system image
		# update & install tailscale
		apt-get update
		apt-get -qy install tailscale && apt -qy clean
		# since storage space on ER-X is limited, we can't keep a second copy
	fi
fi

if [ -n "\$reload" ]; then
	systemctl --no-block restart tailscaled
fi
EOF

chmod 755 /config/scripts/post-config.d/tailscale.sh

