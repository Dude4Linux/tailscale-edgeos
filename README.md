# Tailscale on EdgeOS

This is a short guide for getting [Tailscale](https://tailscale.com/) running on the Ubiquiti EdgeRouter platform. EdgeOS 2.0+ is required to make use of the systemd unit file shipped by Tailscale. EdgeOS 3.0+ includes WireGuard support, but Tailscale ships its own tailored WireGuard implementation, requiring additional storage space.

This was originally inspired by [lg](https://github.com/lg)'s [gist](https://gist.github.com/lg/6f80593bd55ca9c9cf886da169a972c3) and [joeshaw](https://github.com/joeshaw)'s [suggestion](https://gist.github.com/lg/6f80593bd55ca9c9cf886da169a972c3#gistcomment-3578594) of putting everything under `/config/tailscale` rather than directly in `/config`, however this guide uses Tailscale's Debian package repository instead of downloading the tarball and manually managing the files.

**EdgeOS 3.0+ Note:** The scripts have been updated to handle the limited flash storage on ER-X routers. The `firstboot.d/tailscale.sh` script now automates several steps that were previously done manually, including installing the Tailscale repository, creating directories, configuring systemd units, and fixing certificate issues. The `post-config.d/tailscale.sh` script conserves space by removing old packages, cleaning the apt cache, and deleting the backup system image before installing Tailscale.

## Installing Tailscale

1. Download and run the `firstboot.d/tailscale.sh` script
   
   Scripts in the `firstboot.d` directory are run after firmware upgrades.
    The `firstboot.d/tailscale.sh` script handles all of the following automatically:
   
   - Fixes the DST Root CA X3 certificate issue
   
   - Installs the Tailscale package repository (if not already configured)
   
   - Creates persistent directories under `/config/tailscale/`
   
   - Configures systemd units for the Tailscale state bind mount and service overrides
   
   - Generates a `post-config.d/tailscale.sh` script which ensures Tailscale is installed

The `firstboot.d/tailscale.sh` script replaces the `post-config.d/tailscale.sh` script each time it runs, making it easier to upgrade to a new version of the scripts.

On ER-X routers with limited flash storage (EdgeOS 3.0+), the `post-config.d/tailscale.sh` script conserves space by removing old `.deb` packages, cleaning the apt cache, and deleting the backup system image before installing Tailscale.

```sh
sudo bash
mkdir -p /config/scripts/firstboot.d
curl -o /config/scripts/firstboot.d/tailscale.sh https://raw.githubusercontent.com/jamesog/tailscale-edgeos/main/firstboot.d/tailscale.sh
chmod 755 /config/scripts/firstboot.d/tailscale.sh
/config/scripts/firstboot.d/tailscale.sh
/config/scripts/post-config.d/tailscale.sh
```

2. Log in to Tailscale
   
    The example below enables subnet routing for one subnet, enables use as an exit node (Tailscale 1.6+), and uses a one-off pre-auth key, which can be generated at https://login.tailscale.com/admin/authkeys
   
    :warning: Remember to replace `192.0.2.0/24` with the subnet(s) you *actually want to expose* to the tailnet.
   
   ```sh
   tailscale up --advertise-routes 192.0.2.0/24 --advertise-exit-node --authkey tskey-XXX
   ```

3. (Optional) If you want `sshd` to explicitly listen on the Tailscale address instead of all addresses:
   
   1. Fetch the override unit
      
      ```sh
      curl -o /config/tailscale/systemd/tailscaled.service.d/before-ssh.conf https://raw.githubusercontent.com/jamesog/tailscale-edgeos/main/systemd/tailscaled.service.d/before-ssh.conf
      systemctl daemon-reload
      ```
   
   2. Exit the shell, enter configure mode and set the listen-address
      
       If you don't currently have any listen-address directives, make sure you add any other addresses you want to access the router by, such as a private network IP.
      
       The Tailscale IP can be found in the admin console, or using `tailscale ip`.
      
      ```sh
      exit
      configure
      set service ssh listen-address <Tailscale IP>
      commit comment "sshd listen on Tailscale IP"
      save && exit
      ```

## Firmware Upgrades

After an EdgeOS upgrade, third-party packages are no longer installed, but the
`firstboot.d/tailscale.sh` script described above ensures Tailscale gets reinstalled. The `firstboot.d/tailscale.sh` script runs automatically after firmware upgrades and regenerates the `post-config.d/tailscale.sh` script. The `post-config.d/tailscale.sh` script runs later in the boot cycle after configuration is complete and networking is available. If Tailscale is not installed, it installs the latest version from the Debian repository; otherwise the existing version continues running.

## Upgrading Tailscale

Upgrading is straightforward as the package manager will do everything for you.

**Note:** DO NOT USE `apt-get upgrade`. This is not supported on EdgeOS and may
result in a broken system.

```
sudo apt-get update
sudo apt-get install tailscale
```

If you want to install a specific version of Tailscale use:

```sh
sudo apt-get install tailscale=X.Y.Z
```

Where `X.Y.Z` is the version you want. This also works for downgrading.

**Note for ER-X (EdgeOS 3.0+):** Due to limited flash storage, the
`post-config.d/tailscale.sh` script automatically cleans up old packages and the backup system image. You do not need to manually copy `.deb` packages to
`/config/data/firstboot/install-packages` — the script installs directly from
the repository each boot.

For routers with more storage, if you consider a version to be "stable" you can
copy the package to flash memory so it survives firmware upgrades:

```sh
sudo bash
rm -f /config/data/firstboot/install-packages/tailscale*.deb
cp /var/cache/apt/archives/tailscale_*.deb /config/data/firstboot/install-packages
```

If you receive an **out of space** error when upgrading, try cleaning the system's images using:

```sh
delete system image
```

If you have a **certificate error** when upgrading, the `firstboot.d` script fixes this automatically (DST Root CA X3 expiration). If you need to correct it manually, it is an [EdgeOS problem](https://community.ui.com/questions/Fix-Solution-Lets-Encrypt-DST-Root-CA-X3-Expiration-Problems-with-IDS-IPS-Signature-Updates-HTTPS-E/0404a626-1a77-4d6c-9b4c-17ea3dea641d) and you can run:

```sh
sudo -i
sed -i 's|^mozilla\/DST_Root_CA_X3\.crt|!mozilla/DST_Root_CA_X3.crt|' /etc/ca-certificates.conf
curl -sk https://letsencrypt.org/certs/isrgrootx1.pem -o /usr/local/share/ca-certificates/ISRG_Root_X1.crt
update-ca-certificates --fresh
```

## Uninstalling

```sh
sudo apt-get purge tailscale
sudo rm /config/scripts/firstboot.d/tailscale.sh /config/scripts/post-config.d/tailscale.sh
configure
delete system package repository tailscale
commit comment "Remove Tailscale repository"
save && exit
```
