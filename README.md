# tios-onprem

Scripts for running EC2-like VMs on our own hardware (first host: `tios-vmhost01`, Dell Precision 7910).
They run on the host itself. tiosaws launches VMs here through the `/onprem/sync` API
(see [tiosaws API](#tiosaws-api)); that Rails code lives in the tiosaws repo.

| File | What it is |
|---|---|
| `setup_kvm_host.sh` | Builds the host: packages, ZFS, VM network, NAT, DNS, Tailscale, services. Safe to re-run. |
| `setup_aws_identity.sh` | Gives the host its AWS identity (IAM Roles Anywhere) for VM role credentials |
| `tiosvm` | Launch and manage VMs (the host's "EC2 API") |
| `tiosvm-metadata` | EC2-style metadata service for the VMs (`169.254.169.254`), including IAM role credentials |
| `tiosvm-agent` | Picks up launches and terminations from tiosaws |

```
 Tailscale users
      |
      +--> 3 EC2 subnet routers (tag:ec2) --> AWS VPC 10.0.0.0/16, 10.1.0.0/16
      |
      +--> KVM host (tag:onprem) ----------> on-prem "VPC" 10.50.0.0/24
                                              +- vm 10.50.0.x
                                              +- vm 10.50.0.y
```

The host is a Tailscale subnet router for `10.50.0.0/24` only, so AWS traffic keeps going
through the EC2 routers. The host also accepts routes, so the VMs can reach AWS through the
EC2 routers. VMs do not run Tailscale themselves, the same as EC2 instances.

## Hosts

### tios-vmhost01 (set up 2026-10-22)

| | |
|---|---|
| Hardware | Dell Precision Tower 7910, 2x Xeon E5-2690 v3 (24 cores / 48 threads), 125 GB RAM |
| OS | Ubuntu 24.04, UEFI boot from Samsung 860 EVO 1 TB `wwn-0x5002538e30442ddd` (LVM, `/` 914 GB) |
| `vmpool` | Samsung 860 EVO 1 TB `wwn-0x5002538e30443743` |
| `bulk` (mirror) | 2x Seagate 6 TB `wwn-0x5000c500c53c04c4`, `wwn-0x5000c500c532f6c7` |
| Unused | SanDisk 240 GB SSD `wwn-0x5001b444a683b2a0` (empty) |
| DNS name | `vm-machine.tioscapital.com` -> `100.84.176.9` (Tailscale IP, does not change) |
| Tailscale | `tios-vmhost01`, `100.84.176.9`, `tag:onprem`, route `10.50.0.0/24` approved |
| Office LAN | `192.168.1.128` on `enp0s25` (DHCP, MAC `18:66:da:40:a2:a0`, reserve it on the router) |
| Login | `ssh tioscapital@vm-machine.tioscapital.com` (key only; `tioscapital` has passwordless sudo) |

## setup_kvm_host.sh

Sets up a fresh Ubuntu 24.04 host. It is safe to re-run: steps that are already done are skipped.

| Step | Result |
|---|---|
| Packages | qemu/KVM, libvirt, virt-install, ZFS, cloud-image-utils, nftables |
| `vmpool` (SSD) | `/var/lib/libvirt/images` for VM root disks, `/var/lib/libvirt/base` for cloud images |
| `bulk` (HDDs, mirrored when given 2 disks) | `/bulk/volumes` for extra VM disks (like EBS), `/bulk/backups` |
| `tiosvpc` network | bridge `tiosvpc0`, gateway `10.50.0.1`, DHCP `.100-.254` (`.2-.99` are kept for fixed IPs) |
| VM DNS | `*.tioscapital.com` is forwarded to the AWS VPC DNS `10.0.0.2` (same answers as on EC2); other names use the host's DNS |
| NAT | `tios-vpc-nat.service` (nftables) lets VMs reach the LAN, the internet and AWS |
| VM services | `tiosvm`, `tiosvm-metadata.service` (169.254.169.254), chrony (169.254.169.123), `tiosvm-reap.timer` |
| Tailscale | `tag:onprem`, `--advertise-routes=10.50.0.0/24 --accept-routes --accept-dns=false` |

### Before you run it: Tailscale admin console

1. **Access controls**: add the tag and allow access. This is what is live now:

   ```jsonc
   "tagOwners": {
     "tag:onprem": ["autogroup:admin"],
   },
   "hosts": {
     "onprem-vms": "10.50.0.0/24",
   },
   "acls": [
     // Tech: added to the existing "full access" rule -> all VMs + the host by name
     {"action": "accept", "src": ["group:tech"],
      "dst": ["10.0.0.0/16:*", "10.1.0.0/16:*", "10.50.0.0/24:*", "tag:onprem:*"]},
     // FTR: added to the existing FTR rule -> all VMs (and the host via 10.50.0.1)
     {"action": "accept", "src": ["group:ftr"], "dst": ["ftr-az-a:*", "...", "onprem-vms:*"]},
     // On-prem VMs -> AWS through the EC2 routers (needed by user data / Salt)
     {"action": "accept", "src": ["tag:onprem"], "dst": ["10.0.0.0/16:*", "10.1.0.0/16:*"]},
   ],
   ```

   Add these to the existing sections. Don't replace them. To give another group access to
   the VMs, add `"onprem-vms:*"` to that group's rule. All VMs share one subnet, so access is
   all-or-nothing per host.

   The `10.50.0.0/24` route is approved by hand after the host joins (Machines > host >
   Edit route settings), the same way as the EC2 subnet routers.

2. **Settings > Keys > Generate auth key**: Reusable, Pre-approved, Tags = `tag:onprem`.
   Save it on the host as a root-only file (for example `/root/tailscale-authkey.txt`, mode 600).
   Keep the master copy with the other secrets, for example in
   `s3://tios-setup-files/puppet-secrets/by.50.server_role/onprem-kvm/tailscale-authkey.txt`.

### Run it

Find the disk IDs. Always use `/dev/disk/by-id` paths, because `sdX` names can change after a reboot:

```bash
lsblk -o NAME,SIZE,MODEL,SERIAL
ls -l /dev/disk/by-id/ | grep -v part | grep wwn-
```

Get the repo onto the host, then run the setup from it:

```bash
# Option A: clone on the host (needs a read-only GitHub deploy key on the host)
sudo git clone git@github.com:tiostech/tios-onprem.git /opt/tios-onprem
# Option B: copy from your laptop
rsync -av --exclude .git ~/dev/tios-onprem/ tioscapital@<host>:tios-onprem/

cd /opt/tios-onprem   # or ~/tios-onprem
sudo ./setup_kvm_host.sh \
  --vm-disk    /dev/disk/by-id/wwn-0x5002538e30443743 \
  --bulk-disks /dev/disk/by-id/wwn-0x5000c500c53c04c4,/dev/disk/by-id/wwn-0x5000c500c532f6c7 \
  --ts-authkey-file /root/tailscale-authkey.txt
```

| Option | Meaning |
|---|---|
| `--vm-disk` | SSD for the `vmpool` pool. Required the first time. |
| `--bulk-disks` | 1 or 2 comma-separated disks for `bulk` (2 = mirror). Optional. |
| `--ts-authkey-file` | Tailscale auth key file. Without it, `tailscale up` prints a login link. |
| `--hostname` | Optional, for example `tios-vmhost02.tioscapital.com` |
| `--wipe` | Allow erasing disks that still have old partitions or data |

Safety: the script refuses the disk that holds `/`, `/boot` or `/boot/efi`, refuses mounted
disks, and stops on disks that have old data unless `--wipe` is given.

The subnet can be changed with `VPC_NET=10.60.0 sudo -E ./setup_kvm_host.sh ...`.
Pick a range that does not overlap AWS (10.0/16, 10.1/16) or users' home networks.

**Re-running** (after a script update): update the copy on the host and run it without the
disk options, because the pools already exist:

```bash
# Option A (clone on the host)
ssh -t tioscapital@vm-machine.tioscapital.com 'cd /opt/tios-onprem && sudo git pull && sudo ./setup_kvm_host.sh --ts-authkey-file /root/tailscale-authkey.txt'
# Option B (copy from your laptop)
rsync -av --exclude .git ~/dev/tios-onprem/ tioscapital@vm-machine.tioscapital.com:tios-onprem/
ssh -t tioscapital@vm-machine.tioscapital.com 'cd tios-onprem && sudo ./setup_kvm_host.sh --ts-authkey-file /root/tailscale-authkey.txt'
```

The network is only changed when no VMs are running on it; otherwise the script warns and skips it.

### Check it worked

On the host:

```bash
zpool status                                        # vmpool + bulk ONLINE
virsh net-list --all                                # tiosvpc: active, autostart
virsh net-dumpxml tiosvpc | grep forwarder          # tioscapital.com -> 10.0.0.2
systemctl is-active tios-vpc-nat                    # active
tailscale status --json | jq .Self.PrimaryRoutes    # ["10.50.0.0/24"] = route approved
dig +short @10.50.0.1 ec2manager-internal.tioscapital.com   # private AWS IP, like on EC2
curl -sk -o /dev/null -w "%{http_code}\n" https://ec2manager-internal.tioscapital.com/  # 200
```

From a Tailscale-connected laptop (group:tech or group:ftr):

```bash
ping 10.50.0.1
ssh tioscapital@vm-machine.tioscapital.com
```

### Troubleshooting

- **Users can't reach VMs**: check that the route is approved (Machines > host > Edit route settings)
  and allowed in the ACLs. Linux clients need `tailscale set --accept-routes`.
- **Docker on the host** sets the iptables FORWARD policy to DROP, which breaks VM routing.
  Don't install Docker on the host. Run it inside a VM.
- **Host LAN broke after `--accept-routes`**: some tailnet router advertises the host's LAN range.
  Run `sudo tailscale set --accept-routes=false`.
- **Internal names don't resolve on the host itself** (for example `ec2manager-internal`): expected.
  The host uses the office DNS (`--accept-dns=false`, like the EC2 routers). VMs resolve them
  through `10.50.0.1`, or test with `dig @10.0.0.2 <name>`.
- **`10.0.0.2` answers DNS, `10.1.0.2` does not**: expected. The VPC DNS only lives at the
  primary CIDR base + 2.
- **Ping to AWS IPs fails but TCP works**: AWS security groups usually block ICMP. Test with
  `nc -zv <ip> <port>` or `curl` instead.

## tiosvm

Launches and manages EC2-like VMs on the host. `setup_kvm_host.sh` installs it to
`/usr/local/bin/tiosvm` (copy `tiosvm` next to the setup script before running it).

```bash
sudo tiosvm launch --name test1 --type cpu4 --disk 50G --user-data ud.sh --tag env=test
sudo tiosvm list
sudo tiosvm console-output test1     # boot + cloud-init log
sudo tiosvm stop test1
sudo tiosvm start test1
sudo tiosvm terminate test1
```

| Command | Like EC2 |
|---|---|
| `launch --name N --type T [--disk 50G] [--user-data F] [--tag K=V]... [--terminate-on-shutdown] [--iam-role R]` | `run-instances` (`--iam-role` = instance profile) |
| `list`, `describe ID\|NAME` | `describe-instances` |
| `start`, `stop`, `reboot`, `terminate ID\|NAME...` | same |
| `console ID\|NAME` | EC2 serial console (Ctrl+] to leave) |
| `console-output ID\|NAME` | `get-console-output` |
| `types` | instance types: EC2 sizes plus tiosaws groups (`cpu4`, `mem30`, ...) |
| `capacity` | free vCPU / RAM on the host |
| `image-update` | download the latest Ubuntu 24.04 cloud image (like a new AMI) |
| `reap` | delete VMs that shut themselves down (runs every minute from `tiosvm-reap.timer`) |

How it works:

| | |
|---|---|
| Instance ID | `i-` + 17 hex characters, like EC2. `--name` is saved as the `Name` tag and doesn't have to be unique. Commands take an ID, or a name if only one VM has it. |
| Image | `/var/lib/libvirt/base/ubuntu-24.04.img` (Ubuntu cloud image). Each VM disk is a thin copy, grown to `--disk` on first boot. Old images stay while VMs still use them. |
| IP | Fixed for the life of the VM, from `10.50.0.10-99`, set inside the VM by cloud-init (not DHCP). IPs that still have a DHCP lease are skipped. Hostname `ip-10-50-0-N`, like EC2. |
| User data | Passed to cloud-init unchanged (bash, `#cloud-config` or MIME multipart, same as EC2). Runs on first boot. |
| SSH | Keys in `/etc/tiosvm/authorized_keys` are added to the `ubuntu` user, like an EC2 key pair. Setup copies them from the admin user. `--ssh-key FILE` uses other keys. |
| Capacity | Launch only succeeds if running VMs leave enough room: host threads for vCPUs (no overcommit) and host RAM minus 8 GB. Otherwise exit code 3 `InsufficientInstanceCapacity`. Stopped VMs don't count. |
| `--terminate-on-shutdown` | When the VM powers itself off, it is deleted within a minute, like EC2 "shutdown behavior: terminate". `tiosvm stop` never deletes a VM. |
| Host reboot | Running VMs start again automatically. VMs stopped with `tiosvm stop` stay stopped. |
| Network filter | Each VM gets libvirt's `clean-traffic` filter: it can only use its own IP and MAC (no spoofing other VMs). |
| Files | State: `/var/lib/tiosvm/instances/<id>.json`. Disks: `/var/lib/libvirt/images/<id>/`. Console log: `/var/log/libvirt/qemu/<id>-console.log`. |

## EC2-style services for VMs

| Address (from a VM) | Served by | Like EC2 |
|---|---|---|
| `http://169.254.169.254` | `tiosvm-metadata.service` on the host (port 8775, nftables DNAT) | Instance metadata (IMDSv1 and IMDSv2) |
| `169.254.169.123` (NTP) | `chrony` on the host | Amazon Time Sync Service |

The metadata service answers for the VM that asks, found by its IP. It covers what Salt,
telegraf, ftrpowerflow and the AWS CLI use:

| Path | Value |
|---|---|
| `/latest/api/token` (PUT) | IMDSv2 token |
| `/latest/meta-data/instance-id` | tiosvm instance ID (`i-...`) |
| `/latest/meta-data/instance-type` | `--type` (for example `m6i.4xlarge`) |
| `/latest/meta-data/local-ipv4`, `hostname`, `local-hostname`, `mac` | the VM's fixed IP and `ip-10-50-0-N` |
| `/latest/meta-data/placement/region` / `availability-zone` | `us-east-1` / `us-east-1-onprem` |
| `/latest/meta-data/tags/instance/<key>` | `--tag` values, plus `Name` |
| `/latest/dynamic/instance-identity/document` | JSON with instanceId, region, instanceType, privateIp, ... |
| `/latest/user-data` | the user data |
| `/latest/meta-data/iam/info`, `iam/security-credentials/<role>` | temporary credentials for the `--iam-role` (see below); 404 if the VM has no role |

Test from a VM:

```bash
TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id
curl -s http://169.254.169.254/latest/dynamic/instance-identity/document
chronyc -h 169.254.169.123 tracking      # or: sudo chronyc sources (if chrony is set to 169.254.169.123)
```

On the host: `journalctl -u tiosvm-metadata` shows every request.

## IAM role credentials for VMs

A VM launched with `--iam-role ROLE` gets temporary credentials for that role from
`169.254.169.254`, like an EC2 instance profile. `aws s3 cp` and the SDKs work with no keys.

```
VM ──169.254.169.254──► tiosvm-metadata ──sts:AssumeRole(ROLE, session = instance ID)──► AWS
                              │
                              └─ host identity: TiosOnpremKvmHost via IAM Roles Anywhere
                                 (certificate /etc/tiosvm/aws/host.crt + host.key)
```

- The host's own role, `TiosOnpremKvmHost`, can only `sts:AssumeRole` into the roles listed in its policy.
- Each VM role must also trust `TiosOnpremKvmHost` in its trust policy (next to `ec2.amazonaws.com`).
- VMs only get their own role: the service finds the VM by IP, and libvirt's `clean-traffic`
  filter stops a VM from using another VM's IP or MAC.
- Credentials last 1 hour (role chaining limit) and are renewed 15 minutes before they expire.
  CloudTrail shows `assumed-role/<ROLE>/<instance ID>`, like EC2.
- Root on the host can get credentials for every allowed role. Treat the host like an AWS admin machine.

### One-time setup

**1. Certificates (on the host, as root).** A private CA (free, no AWS Private CA) and a host certificate.
The CA lives in `/root/tios-onprem-ca` (root only); the host certificate in `/etc/tiosvm/aws`:

```bash
umask 077; mkdir -p /root/tios-onprem-ca && cd /root/tios-onprem-ca
openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
  -keyout ca.key -out ca.crt -subj "/O=Tios Capital/CN=Tios Onprem CA" \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign"
openssl req -new -newkey rsa:2048 -nodes -keyout /etc/tiosvm/aws/host.key -out host.csr \
  -subj "/O=Tios Capital/CN=tios-vmhost01"
openssl x509 -req -in host.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 365 -sha256 \
  -out /etc/tiosvm/aws/host.crt \
  -extfile <(printf "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\n")
cp ca.crt /etc/tiosvm/aws/
```

Copy `ca.key` to the password manager, then delete it from the host. It is only needed to issue
new host certificates. The host certificate expires after 1 year (tios-vmhost01: 2027-10-23).

**2. AWS console (IAM admin; `smashal-cli` can't change IAM).**

- IAM Roles Anywhere > trust anchor `tios-onprem`, source "External certificate bundle" = `ca.crt`.
- IAM role `TiosOnpremKvmHost`, trust policy:

  ```json
  {"Version": "2012-10-17", "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "rolesanywhere.amazonaws.com"},
    "Action": ["sts:AssumeRole", "sts:TagSession", "sts:SetSourceIdentity"],
    "Condition": {
      "StringEquals": {"aws:PrincipalTag/x509Subject/CN": "tios-vmhost01"},
      "ArnEquals": {"aws:SourceArn": "<trust anchor ARN>"}}}]}
  ```

  Inline permission policy (one `Resource` per VM role allowed on-prem):

  ```json
  {"Version": "2012-10-17", "Statement": [{
    "Effect": "Allow",
    "Action": ["sts:AssumeRole", "sts:SetSourceIdentity", "sts:TagSession"],
    "Resource": ["arn:aws:iam::345847152578:role/TiosSysSetupFtrpowerflow"]}]}
  ```

- IAM Roles Anywhere > profile `tios-onprem-kvm-host` with role `TiosOnpremKvmHost`.
- Each VM role (e.g. `TiosSysSetupFtrpowerflow`) > Trust relationships: keep the `ec2.amazonaws.com`
  statement and add:

  ```json
  {"Effect": "Allow",
   "Principal": {"AWS": "arn:aws:iam::345847152578:role/TiosOnpremKvmHost"},
   "Action": ["sts:AssumeRole", "sts:SetSourceIdentity", "sts:TagSession"]}
  ```

  `sts:SetSourceIdentity` and `sts:TagSession` are required in **both** policies: Roles Anywhere
  stamps the host session with a source identity (the certificate serial) and session tags
  (`x509Subject/CN`, ...), and AWS passes both on when the host assumes the VM role. Without them
  AssumeRole fails with AccessDenied.

**3. Host.** Copy `setup_aws_identity.sh` to the host and run it with the two ARNs:

```bash
sudo ./setup_aws_identity.sh \
  --trust-anchor-arn arn:aws:rolesanywhere:us-east-1:345847152578:trust-anchor/... \
  --profile-arn      arn:aws:rolesanywhere:us-east-1:345847152578:profile/... \
  --test-role TiosSysSetupFtrpowerflow
```

It installs `aws_signing_helper`, writes `/etc/tiosvm/aws/config` (profile `host`), sets the file
permissions (root + `tiosvm-metadata` only), tests the host identity and the role, and restarts
`tiosvm-metadata`.

**4. Test.**

```bash
sudo tiosvm launch --name iamtest --type cpu2 --disk 20G --iam-role TiosSysSetupFtrpowerflow
# in the VM (after installing the AWS CLI):
aws sts get-caller-identity          # assumed-role/TiosSysSetupFtrpowerflow/i-...
```

To allow another role on-prem: add it to `TiosOnpremKvmHost`'s permission policy and add the
`TiosOnpremKvmHost` statement to that role's trust policy.

## tiosaws launches (tiosvm-agent)

`ftrpowerflow` can launch on the on-prem host with `target: "onprem"` (default `ec2`). The other
ftrpowerflow launchers (`ftrpowerflowr`, `ftrpowerflowweb`) stay EC2-only.

```
POST launchers/ftrpowerflow  {env, target: "onprem", ...}
  tiosaws (Ec2Helpers::Onprem): same user data as EC2, instance IDs created up front,
    Cluster/Ec2Request/Ec2Instance records (AZ us-east-1-onprem), one request per instance
    in Redis list onprem.launch.queue
        ^
        | POST /onprem/sync every 10s (header X-Onprem-Agent-Token)
        |   sends: VMs on the host (ID, IP, state), gone, failed, requeue
        |   gets:  next launch, IDs to terminate
  tiosvm-agent (host) -> tiosvm launch --instance-id ... / tiosvm terminate ...
```

- tiosaws can't reach the host, so the agent pulls. EC2 launches never go through the queue.
- Self-shutdown: `instances/self_shutdown_terminate` with an on-prem ID goes to
  `onprem.terminate.queue` (agent runs `tiosvm terminate`); EC2 IDs go to EC2 as before.
- Full host: `tiosvm` exits 3, the agent sends the request back and it waits at the front of the queue.
- A launch the agent claimed is written to `/var/lib/tiosvm/agent/spool/` first, so a restart doesn't lose it.
- Not covered: `instances/terminate` / `stop` by name filter (EC2 describe), spot, AZs, security groups, load balancers.

### Setup

1. tiosaws (rails console of the environment the host should serve, e.g. stage):

   ```ruby
   $redis.set(Ec2Helpers::Onprem::AGENT_TOKEN_KEY, SecureRandom.hex(32))
   $redis.get(Ec2Helpers::Onprem::AGENT_TOKEN_KEY)   # copy for step 2
   ```

2. Host:

   ```bash
   sudo install -m 600 /dev/null /etc/tiosvm/agent-token && sudo nano /etc/tiosvm/agent-token   # paste the token
   sudo tee /etc/tiosvm/agent.conf <<'EOF'
   TIOSAWS_URL=https://ec2manager-stage.tioscapital.com
   DNS_SERVER=10.50.0.1
   INTERVAL=10
   EOF
   sudo systemctl restart tiosvm-agent && journalctl -u tiosvm-agent -f
   ```

   `DNS_SERVER=10.50.0.1` makes the agent look up the tiosaws name through the VM network's DNS
   (which forwards `tioscapital.com` to the AWS VPC DNS); the host's own DNS isn't changed.

3. Launch:

   ```bash
   curl -X POST https://ec2manager-stage-internal.tioscapital.com/launchers/ftrpowerflow \
     -H 'Content-Type: application/json' \
     -d '{"env": "stage", "target": "onprem", "instance_type": "m6i.xlarge"}'
   ```

   Watch it with `sudo tiosvm list` and `sudo tiosvm console-output <id>` on the host.

## Next phases

Done on tios-vmhost01: phase 1 (host setup), phase 2 (`tiosvm`), phase 3 (metadata, time and IAM
role credentials). AWS side for tios-vmhost01 (2026-10-23): trust anchor `tios-onprem`
(`trust-anchor/d98e7c0c-8e31-4d9e-8ed4-b6b835d19511`), profile `tios-onprem-kvm-host`
(`profile/7b042cf3-97dc-4758-b63c-f17cda61850e`), role `TiosOnpremKvmHost`; allowed VM role:
`TiosSysSetupFtrpowerflow`.

1. Phase 4 (tiosaws `target: "onprem"` for `ftrpowerflow` + `tiosvm-agent`) is written; test on stage.

## tiosaws API

This repo and tiosaws (`app/modules/ec2_helpers/onprem.rb`, `app/controllers/onprem_controller.rb`)
meet at one API. If either side changes it, change the other side too.

**`POST <TIOSAWS_URL>/onprem/sync`**, header `X-Onprem-Agent-Token: <token>` (Redis key
`onprem.agent_token` in tiosaws, `/etc/tiosvm/agent-token` on the host), JSON body, all keys optional:

```json
{
  "instances": [{"id": "i-998b8fd6ca7274863", "ip": "10.50.0.11", "state": "running"}],
  "gone":      ["i-..."],
  "failed":    [{"id": "i-...", "error": "text"}],
  "requeue":   [<launch request>]
}
```

Response:

```json
{ "launch": <launch request or null>, "terminate": ["i-..."] }
```

No launch is handed out in a response to a sync that requeued one.

**Launch request** (one per instance, created by tiosaws):

| Field | Example | Used as |
|---|---|---|
| `instance_id` | `i-998b8fd6ca7274863` | `tiosvm launch --instance-id` |
| `name` | `ftrpowerflow-console.vpcint.tioscapital.com` | `--name` (EC2 `Name` tag) |
| `instance_type` | `m6i.xlarge` | `--type` (must be in `tiosvm types`) |
| `disk_gb` | `50` | `--disk 50G` |
| `iam_role` | `TiosSysSetupFtrpowerflow` | `--iam-role` |
| `terminate_on_shutdown` | `true` | `--terminate-on-shutdown` |
| `tags` | `{"env": "production", ...}` | `--tag key=value` |
| `user_data_base64` | | decoded into `--user-data` |
| `request_uuid`, `cluster_uuid` | | for tiosaws' own records |

Self-shutdown: an on-prem VM calls tiosaws `instances/self_shutdown_terminate` like an EC2 instance;
tiosaws recognises on-prem IDs (Redis set `onprem.instances`) and returns them in `terminate`.

## Hardware notes

- 2026-10-23: a memory channel on CPU 2 threw corrected memory errors (thousands of machine-check
  events per minute), which also hung the onboard network card (e1000e "Detected Hardware Unit
  Hang"). The host stayed up without network for 3 days, then would not POST until the DIMMs were
  reseated on 2026-10-28. All 16 DIMMs are detected again with no errors since.
- `rasdaemon` now records memory/hardware errors with the DIMM slot:
  `sudo ras-mc-ctl --summary` and `sudo ras-mc-ctl --errors`. If errors return, replace that DIMM
  (8 GB DDR4-2133 ECC RDIMM, part `18ASF1G72PZ-2G1A2`).
- `smartmontools` watches the disks: `sudo smartctl -H -A /dev/sdX`.
