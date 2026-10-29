#!/usr/bin/env bash
#
# setup_kvm_host.sh - turn a fresh Ubuntu 24.04 machine into a Tios on-prem KVM host.
#
# What it does (safe to re-run; finished steps are skipped):
#   1. Installs KVM/libvirt, ZFS and cloud-init tooling
#   2. Creates ZFS pool "vmpool" on the SSD (VM disks) and "bulk" on the HDDs (mirror if 2 disks)
#   3. Creates the "tiosvpc" libvirt network 10.50.0.0/24 (gateway 10.50.0.1) with NAT out
#   4. Joins Tailscale with tag:onprem and advertises 10.50.0.0/24 as a subnet router
#   5. Installs tiosvm (VM launcher), the VM SSH keys, and the ubuntu 24.04 cloud image
#   6. Runs EC2-style services for the VMs: metadata at 169.254.169.254, time at 169.254.169.123
#   7. Installs tiosvm-agent (on-prem launches from tiosaws; needs /etc/tiosvm/agent.conf + agent-token)
#
# Usage:
#   sudo ./setup_kvm_host.sh \
#     --vm-disk    /dev/disk/by-id/wwn-0x5002538e30443743 \
#     --bulk-disks /dev/disk/by-id/wwn-0x5000c500c53c04c4,/dev/disk/by-id/wwn-0x5000c500c532f6c7 \
#     --ts-authkey-file /root/tailscale-authkey.txt
#
# See README.md (github.com/tiostech/tios-onprem) for the Tailscale admin prerequisites.

set -euo pipefail
# Note: no "cmd | grep -q" below. grep -q exits early, cmd gets SIGPIPE and
# pipefail turns a match into a failure. Use "grep ... >/dev/null" instead.

# ---- Settings (override with environment variables) -------------------------
VPC_NET="${VPC_NET:-10.50.0}"            # first three octets of the /24
VPC_CIDR="${VPC_NET}.0/24"
VPC_GATEWAY="${VPC_NET}.1"
VPC_DHCP_START="${VPC_NET}.100"          # .2-.99 are left for fixed reservations
VPC_DHCP_END="${VPC_NET}.254"
NET_NAME="tiosvpc"
BRIDGE="tiosvpc0"
TS_TAG="tag:onprem"
AWS_DNS="${AWS_DNS:-10.0.0.2}"           # VPC DNS, reached through the EC2 Tailscale routers
AWS_DNS_DOMAIN="tioscapital.com"         # private zone names, e.g. ec2manager-internal
METADATA_PORT=8775                        # tiosvm-metadata; VMs reach it as 169.254.169.254:80

VM_POOL="vmpool"
BULK_POOL="bulk"
IMAGES_DIR="/var/lib/libvirt/images"     # VM root disks
BASE_DIR="/var/lib/libvirt/base"         # Ubuntu cloud images (like AMIs)
VOLUMES_DIR="/bulk/volumes"              # extra VM disks (like EBS)
BACKUPS_DIR="/bulk/backups"

# ---- Arguments --------------------------------------------------------------
VM_DISK=""
BULK_DISKS=""
TS_AUTHKEY_FILE=""
NEW_HOSTNAME=""
WIPE=0

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --vm-disk)          VM_DISK="$2"; shift 2 ;;
    --bulk-disks)       BULK_DISKS="$2"; shift 2 ;;
    --ts-authkey-file)  TS_AUTHKEY_FILE="$2"; shift 2 ;;
    --hostname)         NEW_HOSTNAME="$2"; shift 2 ;;
    --wipe)             WIPE=1; shift ;;
    -h|--help)          usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

log()  { echo; echo "==> $*"; }
skip() { echo "    (already done) $*"; }
warn() { echo "WARNING: $*" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run with sudo."
. /etc/os-release
[ "${VERSION_ID:-}" = "24.04" ] || warn "Written for Ubuntu 24.04, this is ${PRETTY_NAME:-unknown}."
[ -e /dev/kvm ] || die "/dev/kvm is missing. Turn on Intel VT-x / AMD-V in the BIOS."
[ -z "$TS_AUTHKEY_FILE" ] || [ -r "$TS_AUTHKEY_FILE" ] || die "Cannot read $TS_AUTHKEY_FILE"

# ---- 0. Hostname (optional) -------------------------------------------------
if [ -n "$NEW_HOSTNAME" ]; then
  log "Setting hostname to $NEW_HOSTNAME"
  short="${NEW_HOSTNAME%%.*}"
  hostnamectl set-hostname "$short"
  sed -i '/^127\.0\.1\.1/d' /etc/hosts
  if [ "$short" = "$NEW_HOSTNAME" ]; then
    sed -i "1a 127.0.1.1 $short" /etc/hosts
  else
    sed -i "1a 127.0.1.1 $NEW_HOSTNAME $short" /etc/hosts
  fi
fi

# ---- 1. Packages -------------------------------------------------------------
log "Installing KVM, libvirt, ZFS and tools"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q \
  qemu-system-x86 qemu-utils libvirt-daemon-system libvirt-clients virtinst ovmf \
  cloud-image-utils dnsmasq-base zfsutils-linux nftables jq curl chrony python3 python3-boto3 bind9-dnsutils rasdaemon libguestfs-tools
apt-get install -y -q --no-install-recommends smartmontools   # no mail packages
systemctl enable --now libvirtd
systemctl enable --now rasdaemon   # logs memory/hardware errors with the exact DIMM slot

if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
  usermod -aG libvirt,kvm "$SUDO_USER"
fi

# ---- 2. Storage --------------------------------------------------------------

# Disks that /, /boot or /boot/efi live on. These are never touched.
system_disks() {
  local mp src
  for mp in / /boot /boot/efi; do
    src=$(findmnt -no SOURCE "$mp" 2>/dev/null) || continue
    lsblk -nrso NAME,TYPE "$src" | awk '$2=="disk"{print $1}'
  done | sort -u
}

# Refuse system disks and mounted disks. Disks with old data need --wipe.
prepare_disk() {
  local disk="$1" real name
  [ -b "$disk" ] || die "$disk is not a disk. Use a /dev/disk/by-id/... path."
  real=$(readlink -f "$disk")
  name=$(basename "$real")
  [ "$(lsblk -dno TYPE "$real")" = "disk" ] || die "$disk is not a whole disk."
  system_disks | grep -x "$name" >/dev/null && die "$disk ($name) holds the operating system. Refusing."
  [ -z "$(lsblk -nro MOUNTPOINT "$real" | tr -d '[:space:]')" ] || die "$disk ($name) has mounted partitions."

  if [ "$(lsblk -nro NAME "$real" | wc -l)" -gt 1 ] || [ -n "$(wipefs "$real")" ]; then
    [ "$WIPE" -eq 1 ] || die "$disk ($name) has old partitions or data. Check it, then re-run with --wipe."
    echo "    wiping $disk ($name, $(lsblk -dno SIZE,MODEL "$real" | xargs))"
    wipefs -a "$real"?* 2>/dev/null || true
    wipefs -a "$real"
    local size_mb=$(( $(blockdev --getsize64 "$real") / 1024 / 1024 ))
    dd if=/dev/zero of="$real" bs=1M count=16 conv=fsync status=none
    dd if=/dev/zero of="$real" bs=1M count=16 seek=$(( size_mb - 16 )) conv=fsync status=none
  fi
}

# create_pool <name> <disk> [<disk>]   (2 disks = mirror)
create_pool() {
  local pool="$1"; shift
  if zpool list "$pool" >/dev/null 2>&1; then skip "zpool $pool exists"; return; fi
  if zpool import -d /dev/disk/by-id "$pool" >/dev/null 2>&1; then skip "imported zpool $pool"; return; fi
  [ $# -gt 0 ] || die "zpool $pool does not exist and no disks were given for it."
  [ $# -le 2 ] || die "Give 1 or 2 disks for $pool."

  local d
  for d in "$@"; do prepare_disk "$d"; done
  local layout=("$@")
  [ $# -eq 2 ] && layout=(mirror "$@")

  echo "    creating zpool $pool: ${layout[*]}"
  zpool create -o ashift=12 \
    -O compression=lz4 -O atime=off -O xattr=sa -O acltype=posixacl \
    -O mountpoint=none "$pool" "${layout[@]}"
}

# ensure_dataset <dataset> <mountpoint> [zfs create options...]
ensure_dataset() {
  local ds="$1" mp="$2"; shift 2
  if zfs list "$ds" >/dev/null 2>&1; then skip "dataset $ds"; return; fi
  if [ -d "$mp" ] && [ -n "$(ls -A "$mp")" ]; then
    die "$mp is not empty. Move its contents away before mounting $ds there."
  fi
  zfs create -o mountpoint="$mp" "$@" "$ds"
}

log "Setting up ZFS storage"
VM_DISKS_ARR=()
[ -n "$VM_DISK" ] && VM_DISKS_ARR=("$VM_DISK")
BULK_DISKS_ARR=()
[ -n "$BULK_DISKS" ] && IFS=',' read -r -a BULK_DISKS_ARR <<< "$BULK_DISKS"

create_pool "$VM_POOL" ${VM_DISKS_ARR[@]+"${VM_DISKS_ARR[@]}"}
ensure_dataset "$VM_POOL/images" "$IMAGES_DIR" -o recordsize=64K
ensure_dataset "$VM_POOL/base"   "$BASE_DIR"

if [ ${#BULK_DISKS_ARR[@]} -gt 0 ] || zpool list "$BULK_POOL" >/dev/null 2>&1; then
  create_pool "$BULK_POOL" ${BULK_DISKS_ARR[@]+"${BULK_DISKS_ARR[@]}"}
  ensure_dataset "$BULK_POOL/volumes" "$VOLUMES_DIR" -o recordsize=64K
  ensure_dataset "$BULK_POOL/backups" "$BACKUPS_DIR"
else
  echo "    no --bulk-disks given, skipping the $BULK_POOL pool"
fi

# Register the directories with libvirt so virt-install / virsh can use them
ensure_virsh_pool() {
  local name="$1" path="$2"
  if ! virsh pool-info "$name" >/dev/null 2>&1; then
    virsh pool-define-as "$name" dir --target "$path" >/dev/null
  fi
  virsh pool-autostart "$name" >/dev/null
  virsh pool-info "$name" | grep 'State:.*running' >/dev/null || virsh pool-start "$name" >/dev/null
}
ensure_virsh_pool default "$IMAGES_DIR"
ensure_virsh_pool base    "$BASE_DIR"
zpool list "$BULK_POOL" >/dev/null 2>&1 && ensure_virsh_pool volumes "$VOLUMES_DIR"

# ---- 3. VM network -----------------------------------------------------------
log "Creating the $NET_NAME network ($VPC_CIDR)"

# Packet forwarding, same as tios-salt/salt/tailscale
cat > /etc/sysctl.d/99-tios-router.conf <<EOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
sysctl -q -p /etc/sysctl.d/99-tios-router.conf

# libvirt's own "default" NAT network (192.168.122.0/24) is not used
if virsh net-info default >/dev/null 2>&1; then
  virsh net-autostart default --disable >/dev/null || true
  virsh net-destroy default >/dev/null 2>&1 || true
fi

# mode='open': libvirt runs DHCP/DNS but adds no firewall rules, so Tailscale
# users can reach the VMs. NAT for outbound traffic is set up below.
# DNS: *.tioscapital.com goes to the AWS VPC DNS, like on EC2. Everything else
# goes to the host's normal DNS, so VMs still work if Tailscale is down.
netxml=$(mktemp)
cat > "$netxml" <<EOF
<network>
  <name>$NET_NAME</name>
  <forward mode='open'/>
  <bridge name='$BRIDGE' stp='on' delay='0'/>
  <dns>
    <forwarder domain='$AWS_DNS_DOMAIN' addr='$AWS_DNS'/>
  </dns>
  <ip address='$VPC_GATEWAY' netmask='255.255.255.0'>
    <dhcp>
      <range start='$VPC_DHCP_START' end='$VPC_DHCP_END'/>
    </dhcp>
  </ip>
</network>
EOF
if ! virsh net-info "$NET_NAME" >/dev/null 2>&1; then
  virsh net-define "$netxml" >/dev/null
elif virsh net-dumpxml "$NET_NAME" | grep "forwarder domain='$AWS_DNS_DOMAIN' addr='$AWS_DNS'" >/dev/null; then
  skip "network $NET_NAME exists"
elif [ -z "$(ls /sys/class/net/$BRIDGE/brif 2>/dev/null)" ]; then
  echo "    updating $NET_NAME (adding $AWS_DNS_DOMAIN -> $AWS_DNS DNS forwarding)"
  # Redefining an existing network needs its current UUID in the XML
  sed -i "s#<name>$NET_NAME</name>#&<uuid>$(virsh net-uuid "$NET_NAME")</uuid>#" "$netxml"
  virsh net-define "$netxml" >/dev/null
  virsh net-destroy "$NET_NAME" >/dev/null 2>&1 || true
else
  warn "$NET_NAME has running VMs, not changing it. Stop the VMs and re-run to add DNS forwarding."
fi
rm -f "$netxml"
virsh net-autostart "$NET_NAME" >/dev/null
virsh net-info "$NET_NAME" | grep 'Active:.*yes' >/dev/null || virsh net-start "$NET_NAME" >/dev/null

# Outbound NAT: VMs reach the LAN, the internet and AWS (via Tailscale) as this host.
mkdir -p /etc/tios
cat > /etc/tios/tiosvpc-nat.nft <<EOF
table ip tios_vpc
delete table ip tios_vpc
table ip tios_vpc {
  # EC2 link-local services for VMs: metadata (tiosvm-metadata) and time (chrony)
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    iifname "$BRIDGE" ip daddr 169.254.169.254 tcp dport 80 dnat to $VPC_GATEWAY:$METADATA_PORT
    iifname "$BRIDGE" ip daddr 169.254.169.123 udp dport 123 dnat to $VPC_GATEWAY:123
  }
  chain input {
    type filter hook input priority filter; policy accept;
    tcp dport $METADATA_PORT iifname != "$BRIDGE" drop
  }
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr $VPC_CIDR ip daddr != $VPC_CIDR oifname != "$BRIDGE" masquerade
  }
  chain forward {
    type filter hook forward priority mangle; policy accept;
    oifname "tailscale0" tcp flags syn tcp option maxseg size set rt mtu
  }
}
EOF
cat > /etc/systemd/system/tios-vpc-nat.service <<EOF
[Unit]
Description=NAT for the Tios on-prem VPC ($VPC_CIDR)
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f /etc/tios/tiosvpc-nat.nft
ExecStop=/usr/sbin/nft delete table ip tios_vpc

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable tios-vpc-nat.service >/dev/null
systemctl restart tios-vpc-nat.service

# ---- 4. Tailscale subnet router ---------------------------------------------
log "Joining Tailscale as a subnet router for $VPC_CIDR ($TS_TAG)"
command -v tailscale >/dev/null || curl -fsSL https://tailscale.com/install.sh | sh
systemctl enable --now tailscaled

ts_state=$(tailscale status --json 2>/dev/null | jq -r '.BackendState // empty' || true)
if [ "$ts_state" = "Running" ]; then
  skip "already logged in, updating settings"
  tailscale set --advertise-routes="$VPC_CIDR" --accept-routes --accept-dns=false
else
  ts_args=(--advertise-tags="$TS_TAG" --advertise-routes="$VPC_CIDR"
           --accept-routes --accept-dns=false --hostname="$(hostname -s)")
  if [ -n "$TS_AUTHKEY_FILE" ]; then
    tailscale up --auth-key="file:$TS_AUTHKEY_FILE" "${ts_args[@]}"
  else
    echo "    No --ts-authkey-file given. Open the login link below to approve this machine."
    tailscale up "${ts_args[@]}"
  fi
fi

# --accept-routes must not take over this host's own LAN
lan_cidr=$(ip -4 route show proto kernel | awk -v br="$BRIDGE" '$0 !~ br && $0 !~ /tailscale0/ {print $1; exit}')
if [ -n "$lan_cidr" ] && ip route show table 52 2>/dev/null | grep "^$lan_cidr " >/dev/null; then
  warn "A Tailscale route overlaps this host's LAN ($lan_cidr). Run 'tailscale set --accept-routes=false' if the LAN breaks."
fi

# ---- 5. tiosvm ----------------------------------------------------------------
log "Installing tiosvm"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
for f in tiosvm tiosvm-metadata tiosvm-agent tiosvm-rebake; do
  if [ -f "$SCRIPT_DIR/$f" ]; then
    install -m 755 "$SCRIPT_DIR/$f" "/usr/local/bin/$f"
  else
    warn "$f not found next to this script. Copy all files to the host and re-run."
  fi
done
mkdir -p /var/lib/tiosvm/instances /etc/tiosvm

# SSH keys put on every VM (the 'ubuntu' user), like an EC2 key pair
if [ ! -s /etc/tiosvm/authorized_keys ] && [ -n "${SUDO_USER:-}" ]; then
  user_keys="$(getent passwd "$SUDO_USER" | cut -d: -f6)/.ssh/authorized_keys"
  if [ -s "$user_keys" ]; then
    install -m 644 "$user_keys" /etc/tiosvm/authorized_keys
    echo "    VM SSH keys: copied from $user_keys to /etc/tiosvm/authorized_keys"
  fi
fi
[ -s /etc/tiosvm/authorized_keys ] || warn "No /etc/tiosvm/authorized_keys. Add SSH public keys there so you can log in to VMs."

# Delete VMs that shut themselves down (EC2 "shutdown behavior: terminate")
cat > /etc/systemd/system/tiosvm-reap.service <<EOF
[Unit]
Description=Terminate tiosvm VMs that shut themselves down

[Service]
Type=oneshot
ExecStart=/usr/local/bin/tiosvm reap
EOF
cat > /etc/systemd/system/tiosvm-reap.timer <<EOF
[Unit]
Description=Run tiosvm reap every minute

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now tiosvm-reap.timer >/dev/null

# EC2-style metadata service for the VMs (169.254.169.254 -> $VPC_GATEWAY:$METADATA_PORT).
# Runs as its own user, which can read the host's AWS identity in /etc/tiosvm/aws
# (set up by setup_aws_identity.sh) to hand out IAM role credentials to VMs.
# Check /etc/passwd, not "id": an older version ran as a systemd DynamicUser of the same name
grep "^tiosvm-metadata:" /etc/passwd >/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin tiosvm-metadata
mkdir -p /etc/tiosvm/aws
chown root:tiosvm-metadata /etc/tiosvm/aws
chmod 750 /etc/tiosvm/aws
cat > /etc/systemd/system/tiosvm-metadata.service <<EOF
[Unit]
Description=tiosvm EC2-style instance metadata service
After=network.target

[Service]
ExecStart=/usr/local/bin/tiosvm-metadata
Environment=TIOSVM_METADATA_PORT=$METADATA_PORT TIOSVM_VPC_CIDR=$VPC_CIDR
Restart=always
User=tiosvm-metadata
Group=tiosvm-metadata
ProtectSystem=strict
ProtectHome=yes
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
if [ -x /usr/local/bin/tiosvm-metadata ]; then
  systemctl enable tiosvm-metadata.service >/dev/null
  systemctl restart tiosvm-metadata.service
fi

# tiosvm-agent: picks up on-prem launches/terminations from tiosaws (POST /onprem/sync).
# Starts only once /etc/tiosvm/agent.conf and /etc/tiosvm/agent-token exist (see README.md).
mkdir -p /var/lib/tiosvm/agent
chmod 700 /var/lib/tiosvm/agent
cat > /etc/systemd/system/tiosvm-agent.service <<EOF
[Unit]
Description=tiosvm agent (on-prem launches from tiosaws)
After=network-online.target libvirtd.service tiosvm-metadata.service
Wants=network-online.target
ConditionPathExists=/etc/tiosvm/agent.conf
ConditionPathExists=/etc/tiosvm/agent-token

[Service]
ExecStart=/usr/local/bin/tiosvm-agent
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable tiosvm-agent.service >/dev/null
if [ -f /etc/tiosvm/agent.conf ] && [ -f /etc/tiosvm/agent-token ]; then
  systemctl restart tiosvm-agent.service
else
  echo "    tiosvm-agent installed; it starts once /etc/tiosvm/agent.conf and agent-token exist"
fi

# Time for the VMs at 169.254.169.123, like the Amazon Time Sync Service
echo "allow $VPC_CIDR" > /etc/chrony/conf.d/tiosvm.conf
systemctl restart chrony

# Download the Ubuntu 24.04 cloud image once (like an AMI)
if [ -x /usr/local/bin/tiosvm ] && [ ! -e "$BASE_DIR/ubuntu-24.04.img" ]; then
  /usr/local/bin/tiosvm image-update
fi

# ---- Summary -----------------------------------------------------------------
log "Done"
zpool list
echo
virsh net-list --all
virsh pool-list --all
echo "Tailscale: $(tailscale ip -4 2>/dev/null || echo 'not connected')"
cat <<EOF

Next steps:
  1. Tailscale admin console > Machines > $(hostname -s) > Edit route settings:
     approve $VPC_CIDR (same as the EC2 subnet routers).
  2. From a Tailscale-connected laptop: ping $VPC_GATEWAY
  3. Log out and back in so '${SUDO_USER:-your user}' can use virsh without sudo.
EOF
