# Logos Storage Node Machine Setup Recipe

This recipe describes how to prepare a fresh machine to run a headless Logos Storage node. It is written for a human operator or an AI agent that can SSH into the target machine and execute administrative commands.

The first section is system-independent. The second section gives the concrete Ubuntu 24.04 setup used for the Linode test node.

## Goal

Set up a machine that:

- Runs Logos Storage as a non-root service user.
- Keeps the REST API bound to localhost only.
- Exposes only the P2P and discovery ports publicly.
- Can be administered over SSH using key-based login.
- Starts the node automatically on boot using the host service manager.

## Target Runtime Shape

| Purpose | Default Used Here | Protocol | Exposure |
|---|---:|---|---|
| SSH | `22` | TCP | Restricted to operator IP |
| P2P listen | `8070` | TCP | Public |
| Discovery | `8090` | UDP | Public |
| REST API | `8080` | TCP | Localhost only |

The storage node command should look conceptually like:

```bash
storage \
  --data-dir=<data-dir> \
  --listen-port=8070 \
  --disc-port=8090
```

Do not pass `--api-bindaddr=0.0.0.0` unless there is a deliberate reason to expose the API. The default API bind address is `127.0.0.1`.

## Generic Setup Steps

1. Provision a machine.

Choose a machine with enough resources for the intended workload. For running the node, a small machine can work. For compiling on the machine, prefer at least 2 vCPU and 2-4 GB RAM. A 1 vCPU / 1 GB RAM machine can build, but slowly and may need extra swap.

2. Configure firewall rules.

Inbound rules:

| Purpose | Protocol | Port | Source |
|---|---:|---:|---|
| SSH | TCP | `22` | Operator IP only, if possible |
| Storage P2P | TCP | `8070` | Public IPv4/IPv6 as needed |
| Storage Discovery | UDP | `8090` | Public IPv4/IPv6 as needed |

Do not open `8080/TCP` publicly. Access the API over SSH tunneling.

3. Create a non-root service user.

Create a dedicated user, for example `storage`. The node process should run as this user, not as `root`.

4. Configure SSH access.

Install the operator public SSH key for the service/admin user. Verify login works before disabling root login. Then harden SSH:

```text
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
```

5. Install build/runtime prerequisites.

Install a C/C++ toolchain, `git`, `cmake`, `curl`, `make`, `bash`, and runtime libraries required by the build. If building from source, install Nim `2.2.10`, preferably through `choosenim`.

6. Clone and build Logos Storage.

Clone `https://github.com/logos-storage/logos-storage-nim.git`, initialize submodules, and build:

```bash
make update
make NIMFLAGS="-d:disableMarchNative"
```

Use low parallelism on small machines:

```bash
make -j1 NIMFLAGS="-d:disableMarchNative"
```

`-d:disableMarchNative` is recommended for Linux amd64 release/test artifacts to avoid leaking build-machine CPU choices into the binary and to avoid known GCC/secp256k1 x86_64 asm failures.

7. Install the binary.

Install the built binary somewhere stable, for example:

```text
/opt/logos-storage/storage
```

Keep source checkout and runtime data separate.

8. Create the data directory.

Use a dedicated persistent data directory owned by the service user, for example:

```text
/var/lib/logos-storage
```

9. Create a service.

Use the platform service manager to run the node as the non-root service user, restart on failure, and start on boot.

10. Verify.

Verify:

- Service is running.
- TCP `8070` listens on all addresses.
- UDP `8090` listens on all addresses.
- TCP `8080` listens only on `127.0.0.1`.
- `GET http://127.0.0.1:8080/api/storage/v1/peerid` returns a peer ID locally.
- External TCP connectivity to `8070` works.

## Ubuntu 24.04 Example

This example assumes:

- Ubuntu 24.04 LTS.
- Initial SSH access as `root`.
- Desired user: `storage`.
- Public IP: replace `SERVER_IP` with the host IP.
- Repository branch: `master`.

### 1. Update The System

```bash
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get -y upgrade
DEBIAN_FRONTEND=noninteractive apt-get -y full-upgrade
reboot
```

Reconnect after reboot and verify:

```bash
apt list --upgradable
test ! -f /var/run/reboot-required
```

### 2. Create The `storage` User

```bash
adduser --disabled-password --gecos "" storage
usermod -aG sudo storage
install -d -m 700 -o storage -g storage /home/storage/.ssh
install -m 600 -o storage -g storage /root/.ssh/authorized_keys /home/storage/.ssh/authorized_keys
```

Optional passwordless sudo for bootstrap/admin work:

```bash
printf 'storage ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/90-storage-user
chmod 440 /etc/sudoers.d/90-storage-user
visudo -cf /etc/sudoers.d/90-storage-user
```

From the operator machine, verify:

```bash
ssh storage@SERVER_IP 'whoami; id; sudo -n true'
```

### 3. Harden SSH

Create a drop-in:

```bash
install -d -m 755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-logos-storage-hardening.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
EOF
sshd -t
systemctl restart ssh || systemctl restart sshd
```

Verify from the operator machine:

```bash
ssh storage@SERVER_IP 'true'
ssh -o BatchMode=yes root@SERVER_IP 'true'
```

The root command should fail.

### 4. Install Packages

```bash
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  build-essential \
  cmake \
  git \
  curl \
  make \
  bash \
  lcov \
  libgomp1 \
  jq \
  ca-certificates \
  pkg-config
```

### 5. Add Swap On Small Machines

On very small machines, for example 1 GB RAM, add a swap file before building:

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

### 6. Install Nim 2.2.10 With `choosenim`

Run as the `storage` user:

```bash
curl https://nim-lang.org/choosenim/init.sh -sSf | sh -s -- -y
export PATH="$HOME/.nimble/bin:$PATH"
choosenim 2.2.10
nim --version
```

Persist PATH:

```bash
grep -qxF 'export PATH=$HOME/.nimble/bin:$PATH' ~/.profile || \
  printf '\nexport PATH=$HOME/.nimble/bin:$PATH\n' >> ~/.profile
```

### 7. Clone And Build

Run as the `storage` user:

```bash
git clone https://github.com/logos-storage/logos-storage-nim.git ~/logos-storage-nim
cd ~/logos-storage-nim
make -j1 update
make -j1 NIMFLAGS="-d:disableMarchNative"
./build/storage --help >/dev/null
```

On larger machines, use higher parallelism, for example:

```bash
make -j"$(nproc)" update
make -j"$(nproc)" NIMFLAGS="-d:disableMarchNative"
```

### 8. Install Binary And Data Directory

```bash
sudo install -d -m 755 -o root -g root /opt/logos-storage
sudo install -m 755 -o root -g root ~/logos-storage-nim/build/storage /opt/logos-storage/storage
sudo install -d -m 700 -o storage -g storage /var/lib/logos-storage
/opt/logos-storage/storage --help >/dev/null
```

### 9. Create `systemd` Service

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
ExecStart=/opt/logos-storage/storage --data-dir=/var/lib/logos-storage --listen-port=8070 --disc-port=8090
Restart=on-failure
RestartSec=10
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=/var/lib/logos-storage

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now logos-storage.service
```

### 10. Verify Service And Ports

```bash
systemctl --no-pager --full status logos-storage.service
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

From the operator machine, verify public TCP reachability:

```bash
timeout 10 bash -c 'cat < /dev/null > /dev/tcp/SERVER_IP/8070' && echo open
```

UDP reachability is harder to verify with a simple shell one-liner. Confirm the firewall rule exists and inspect node logs for discovery startup and advertised `/udp/8090` addresses.

## API Access From Operator Machine

Keep the API private and tunnel over SSH:

```bash
ssh -N -L 127.0.0.1:18080:127.0.0.1:8080 storage@SERVER_IP
```

Then use:

```bash
curl http://127.0.0.1:18080/api/storage/v1/peerid
```

In this repository, `scripts/storage-test.sh` manages this tunnel automatically for commands targeting `remote`.

## Operational Commands

```bash
sudo systemctl start logos-storage.service
sudo systemctl stop logos-storage.service
sudo systemctl restart logos-storage.service
systemctl status logos-storage.service
journalctl -u logos-storage.service -f
```

## Troubleshooting

### SSH Hangs During Build

Symptoms:

```text
Connection timed out during banner exchange
```

Likely cause: small VM overloaded by compilation. Use `make -j1`, add swap, or build on a larger machine and copy the binary.

### REST API Is Unreachable Externally

This is expected. The REST API should bind to `127.0.0.1:8080`. Use SSH tunneling.

### Node Has No Peers

Check:

- Firewall allows `8070/TCP` and `8090/UDP`.
- Service logs show public IP in advertised addresses.
- The machine has public internet access.
- The network preset is the intended one, for example `logos.test`.

### Data Directory Permissions Warning

The node may correct permissions on startup. Prefer setting the directory explicitly:

```bash
sudo chmod 700 /var/lib/logos-storage
sudo chown storage:storage /var/lib/logos-storage
```

## Security Notes

- Do not run the node as `root`.
- Do not expose API port `8080` publicly.
- Restrict SSH source IPs in the cloud firewall.
- Keep outbound traffic allowed unless there is a specific network policy.
- Treat the node private key in the data directory as sensitive.
