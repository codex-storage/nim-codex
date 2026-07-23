# Ubuntu Logos Storage Node Setup

This guide describes how to prepare an Ubuntu machine to run a public Logos Storage node. It is written so a human operator or automation agent can perform the setup over SSH.

The expected entry point is root SSH access using public-key authentication:

```bash
ssh root@SERVER_IP
```

After the `storage` account is created and verified, root SSH access should be disabled.

## Target Shape

The finished machine should:

- Run Logos Storage as the non-root `storage` user.
- Store runtime data in `/var/lib/logos-storage`.
- Store node configuration in `/home/storage/.logos-storage/config.toml`.
- Install the node binary at `/opt/logos-storage/storage`.
- Run the node through `logos-storage.service`.
- Keep the REST API bound to `127.0.0.1:8080`.
- Expose only the storage P2P and discovery ports publicly.

Default ports:

| Purpose | Protocol | Port | Exposure |
|---|---:|---:|---|
| SSH | TCP | `22` | Operator IP only, if possible |
| P2P listen | TCP | `8070` | Public |
| Discovery | UDP | `8090` | Public |
| REST API | TCP | `8080` | Localhost only |

## Inputs

Choose these before starting:

| Variable | Example | Notes |
|---|---|---|
| `SERVER_IP` | `172.235.163.25` | Public address of the Ubuntu host |
| `REPO_URL` | `https://github.com/logos-storage/logos-storage-nim.git` | Source repository |
| `REPO_REF` | `master` | Branch, tag, or commit to build |
| `NETWORK` | `logos.test` | Must appear in `storage --help` after build |
| `P2P_PORT` | `8070` | TCP listen port |
| `DISC_PORT` | `8090` | UDP discovery port |
| `LOG_LEVEL` | `info` | Runtime log level |

## 1. Update The Machine

Run as `root`:

```bash
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get -y upgrade
DEBIAN_FRONTEND=noninteractive apt-get -y full-upgrade
reboot
```

Reconnect as `root` after reboot and verify:

```bash
apt list --upgradable
test ! -f /var/run/reboot-required
```

## 2. Create The `storage` Account

Run as `root`:

```bash
adduser --disabled-password --gecos "" storage
usermod -aG sudo storage
install -d -m 700 -o storage -g storage /home/storage/.ssh
install -m 600 -o storage -g storage /root/.ssh/authorized_keys /home/storage/.ssh/authorized_keys
```

For automated setup, temporary passwordless sudo is useful:

```bash
printf 'storage ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/90-storage-user
chmod 440 /etc/sudoers.d/90-storage-user
visudo -cf /etc/sudoers.d/90-storage-user
```

From the operator machine, verify the `storage` account before disabling root SSH:

```bash
ssh storage@SERVER_IP 'whoami; id; sudo -n true'
```

Expected output should show `storage`, membership in `sudo`, and successful passwordless `sudo` if the temporary sudoers file was installed.

## 3. Disable Root SSH

Do this only after `ssh storage@SERVER_IP` works.

Run as `root` or as `storage` with `sudo`:

```bash
sudo install -d -m 755 /etc/ssh/sshd_config.d
sudo tee /etc/ssh/sshd_config.d/99-logos-storage-hardening.conf >/dev/null <<'EOF'
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
EOF
sudo sshd -t
sudo systemctl restart ssh || sudo systemctl restart sshd
```

From the operator machine, verify:

```bash
ssh storage@SERVER_IP 'true'
ssh -o BatchMode=yes root@SERVER_IP 'true'
```

The `storage` command should succeed. The `root` command should fail.

Continue the remaining steps as `storage`.

## 4. Configure Firewall Rules

Use the cloud firewall and/or host firewall to allow:

| Purpose | Protocol | Port | Source |
|---|---:|---:|---|
| SSH | TCP | `22` | Operator IP only, if possible |
| Storage P2P | TCP | `8070` | Public IPv4/IPv6 as needed |
| Storage Discovery | UDP | `8090` | Public IPv4/IPv6 as needed |

Do not open `8080/TCP` publicly. Access the REST API through SSH tunneling when needed:

```bash
ssh -N -L 127.0.0.1:18080:127.0.0.1:8080 storage@SERVER_IP
```

## 5. Install Packages

Run as `storage`:

```bash
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  build-essential \
  cmake \
  git \
  curl \
  make \
  bash \
  libgomp1 \
  jq \
  ca-certificates \
  pkg-config
```

Optional packages:

```bash
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y lcov
```

## 6. Add Swap On Small Machines

On very small machines, for example 1 GB RAM, add swap before building:

```bash
if [ ! -f /swapfile ]; then
  sudo fallocate -l 2G /swapfile || sudo dd if=/dev/zero of=/swapfile bs=1M count=2048
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
fi
grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
free -h
```

## 7. Install Nim 2.2.10

Run as `storage`:

```bash
curl https://nim-lang.org/choosenim/init.sh -sSf | sh -s -- -y
export PATH="$HOME/.nimble/bin:$PATH"
choosenim 2.2.10
nim --version
```

Persist the Nim path:

```bash
grep -qxF 'export PATH=$HOME/.nimble/bin:$PATH' ~/.profile || \
  printf '\nexport PATH=$HOME/.nimble/bin:$PATH\n' >> ~/.profile
```

## 8. Clone And Build

Run as `storage`:

```bash
REPO_URL="https://github.com/logos-storage/logos-storage-nim.git"
REPO_REF="master"

git clone "$REPO_URL" ~/logos-storage-nim
cd ~/logos-storage-nim
git checkout "$REPO_REF"
make -j1 update
make -j1 NIMFLAGS="-d:disableMarchNative"
./build/storage --help >/dev/null
```

On larger machines, use more parallelism:

```bash
make -j"$(nproc)" update
make -j"$(nproc)" NIMFLAGS="-d:disableMarchNative"
```

`-d:disableMarchNative` is recommended for Linux amd64 release/test artifacts. It avoids leaking build-machine CPU choices into the binary and avoids known GCC/secp256k1 x86_64 asm failures caused by `-march=native`.

Before installing, verify the intended network preset is embedded in the binary:

```bash
NETWORK="logos.test"
./build/storage --help | grep -A8 -- '--network'
./build/storage --help | grep -q "$NETWORK"
```

If the intended network is not listed, update the source branch/tag or `network_presets.json`, rebuild, and verify again before continuing.

## 9. Install Binary, Data Directory, And Config

Run as `storage`:

```bash
sudo install -d -m 755 -o root -g root /opt/logos-storage
sudo install -m 755 -o root -g root ~/logos-storage-nim/build/storage /opt/logos-storage/storage
sudo install -d -m 700 -o storage -g storage /var/lib/logos-storage
sudo install -d -m 755 -o storage -g storage /home/storage/.logos-storage
/opt/logos-storage/storage --help >/dev/null
```

Create `/home/storage/.logos-storage/config.toml`:

```bash
NETWORK="logos.test"
LOG_LEVEL="info"
P2P_PORT="8070"
DISC_PORT="8090"

tmp_config="$(mktemp)"
cat > "$tmp_config" <<EOF
data-dir = "/var/lib/logos-storage"
disc-port = $DISC_PORT
listen-port = $P2P_PORT
log-level = "$LOG_LEVEL"
network = "$NETWORK"
EOF
sudo install -m 644 -o storage -g storage "$tmp_config" /home/storage/.logos-storage/config.toml
rm -f "$tmp_config"
```

The REST API binds to `127.0.0.1:8080` by default. Only add `api-bindaddr` if you have a specific reason:

```toml
api-bindaddr = "127.0.0.1"
api-port = 8080
```

Do not set `api-bindaddr = "0.0.0.0"` unless you deliberately want the REST API exposed.

Verify the config file:

```bash
stat -c '%U %G %a %n' /home/storage/.logos-storage/config.toml
nl -ba /home/storage/.logos-storage/config.toml
```

Expected mode is `644` and owner is `storage:storage`.

## 10. Create The systemd Service

Run as `storage`:

```bash
sudo tee /etc/systemd/system/logos-storage.service >/dev/null <<'EOF'
[Unit]
Description=Logos Storage Node
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=storage
Group=storage
WorkingDirectory=/var/lib/logos-storage
ExecStart=/opt/logos-storage/storage --config-file=/home/storage/.logos-storage/config.toml
Restart=on-failure
RestartSec=10
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=/var/lib/logos-storage /home/storage/.logos-storage

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now logos-storage.service
```

## 11. Verify The Node

Run as `storage`:

```bash
systemctl --no-pager --full status logos-storage.service
systemctl cat logos-storage.service
ps -o user,group,pid,cmd -C storage
ss -lntup | grep -E ':(8070|8080|8090)\b'
curl -fsS http://127.0.0.1:8080/api/storage/v1/peerid
curl -fsS http://127.0.0.1:8080/api/storage/v1/spr
journalctl -u logos-storage.service --no-pager -n 80
```

Expected bindings:

```text
udp 0.0.0.0:8090
tcp 127.0.0.1:8080
tcp 0.0.0.0:8070
```

Expected process user:

```text
storage storage ... /opt/logos-storage/storage --config-file=/home/storage/.logos-storage/config.toml
```

From the operator machine, verify public TCP reachability:

```bash
timeout 10 bash -c 'cat < /dev/null > /dev/tcp/SERVER_IP/8070' && echo open
```

UDP reachability is harder to verify with a shell one-liner. Confirm firewall rules and inspect logs for discovery startup and advertised `/udp/8090` addresses.

## Update Procedure

Run as `storage`:

```bash
cd ~/logos-storage-nim
git fetch --all --prune
git checkout REPO_REF
git pull --ff-only
make -j1 update
make -j1 NIMFLAGS="-d:disableMarchNative"
./build/storage --help | grep -A8 -- '--network'
./build/storage --help | grep -q 'logos.test'
sudo systemctl stop logos-storage.service
sudo install -m 755 -o root -g root ./build/storage /opt/logos-storage/storage
sudo systemctl reset-failed logos-storage.service
sudo systemctl start logos-storage.service
systemctl --no-pager --full status logos-storage.service
journalctl -u logos-storage.service --no-pager -n 80
```

To change node configuration, edit `/home/storage/.logos-storage/config.toml` and restart:

```bash
sudoedit /home/storage/.logos-storage/config.toml
sudo systemctl restart logos-storage.service
systemctl --no-pager --full status logos-storage.service
journalctl -u logos-storage.service --no-pager -n 80
```

## Operational Commands

```bash
sudo systemctl start logos-storage.service
sudo systemctl stop logos-storage.service
sudo systemctl restart logos-storage.service
systemctl --no-pager --full status logos-storage.service
journalctl -u logos-storage.service -f
```

## Troubleshooting

### Invalid Network Preset

Symptoms:

```text
Invalid network preset: logos.test
```

Cause: the installed binary does not embed that network in `network_presets.json`.

Check:

```bash
/opt/logos-storage/storage --help | grep -A8 -- '--network'
```

Fix: checkout a branch/tag with the desired preset, rebuild, reinstall, and restart.

### Service Restart Loop

Check the real startup error:

```bash
systemctl --no-pager --full status logos-storage.service
journalctl -u logos-storage.service --no-pager -n 120
```

Common causes are invalid config TOML, invalid network preset, occupied ports, or bad data directory permissions.

### Build Hangs Or SSH Disconnects

Small VMs can become overloaded during compilation. Add swap and use `make -j1`.

### REST API Is Unreachable Externally

This is expected. The REST API should bind to `127.0.0.1:8080`. Use SSH tunneling.

### Node Has No Peers

Check:

- Firewall allows `8070/TCP` and `8090/UDP`.
- `network` in config is the intended preset.
- The installed binary knows that preset.
- The machine has public internet access.
- Service logs show public IP addresses in advertised records.

### Data Directory Permissions Warning

Prefer strict ownership and mode:

```bash
sudo chmod 700 /var/lib/logos-storage
sudo chown storage:storage /var/lib/logos-storage
```

## Security Notes

- Do not run the node as `root`.
- Do not expose REST API port `8080` publicly.
- Restrict SSH source IPs in the cloud firewall when possible.
- Keep outbound traffic allowed unless there is a specific network policy.
- Treat `/var/lib/logos-storage/key` and other node identity files as sensitive.
- Remove temporary passwordless sudo if the machine no longer needs automated administration.

To remove temporary passwordless sudo:

```bash
sudo rm -f /etc/sudoers.d/90-storage-user
sudo -k
```
