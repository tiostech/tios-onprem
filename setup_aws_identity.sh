#!/usr/bin/env bash
#
# setup_aws_identity.sh - give a Tios on-prem KVM host its AWS identity (IAM Roles Anywhere),
# so tiosvm-metadata can hand out IAM role credentials to VMs launched with --iam-role.
#
# Before running it (see README.md "IAM role credentials for VMs"):
#   - /etc/tiosvm/aws/host.crt and host.key exist (signed by the Tios on-prem CA)
#   - an AWS admin created the trust anchor, the TiosOnpremKvmHost role and the profile
#
# Usage:
#   sudo ./setup_aws_identity.sh \
#     --trust-anchor-arn arn:aws:rolesanywhere:us-east-1:345847152578:trust-anchor/... \
#     --profile-arn      arn:aws:rolesanywhere:us-east-1:345847152578:profile/... \
#     [--role-arn arn:aws:iam::345847152578:role/TiosOnpremKvmHost] \
#     [--test-role TiosSysSetupFtrpowerflow]

set -euo pipefail

AWS_DIR="/etc/tiosvm/aws"
CERT="$AWS_DIR/host.crt"
KEY="$AWS_DIR/host.key"
REGION="us-east-1"
HELPER="/usr/local/bin/aws_signing_helper"
HELPER_VERSION="1.7.0"
HELPER_URL="https://rolesanywhere.amazonaws.com/releases/$HELPER_VERSION/X86_64/Linux/aws_signing_helper"
SERVICE_USER="tiosvm-metadata"

TRUST_ANCHOR_ARN=""
PROFILE_ARN=""
ROLE_ARN="arn:aws:iam::345847152578:role/TiosOnpremKvmHost"
TEST_ROLE=""

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
die()   { echo "ERROR: $*" >&2; exit 1; }
warn()  { echo "WARNING: $*" >&2; }
log()   { echo; echo "==> $*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --trust-anchor-arn) TRUST_ANCHOR_ARN="$2"; shift 2 ;;
    --profile-arn)      PROFILE_ARN="$2"; shift 2 ;;
    --role-arn)         ROLE_ARN="$2"; shift 2 ;;
    --test-role)        TEST_ROLE="$2"; shift 2 ;;
    -h|--help)          usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "Run with sudo."
[[ "$TRUST_ANCHOR_ARN" == arn:aws:rolesanywhere:*:trust-anchor/* ]] || die "--trust-anchor-arn is missing or wrong."
[[ "$PROFILE_ARN" == arn:aws:rolesanywhere:*:profile/* ]] || die "--profile-arn is missing or wrong."
[[ "$ROLE_ARN" == arn:aws:iam::*:role/* ]] || die "--role-arn is wrong."
[ -s "$CERT" ] || die "$CERT is missing. Create the host certificate first (README.md)."
[ -s "$KEY" ] || die "$KEY is missing. Create the host certificate first (README.md)."
grep "^$SERVICE_USER:" /etc/passwd >/dev/null || die "User $SERVICE_USER is missing. Run setup_kvm_host.sh first."
[ -e "$AWS_DIR/ca.key" ] && warn "$AWS_DIR/ca.key is still on the host. Move it to the password manager and delete it here."

log "Checking the host certificate"
openssl x509 -in "$CERT" -noout -subject -enddate
cert_mod=$(openssl x509 -in "$CERT" -noout -pubkey | openssl sha256)
key_mod=$(openssl pkey -in "$KEY" -pubout | openssl sha256)
[ "$cert_mod" = "$key_mod" ] || die "host.key does not belong to host.crt."

log "Installing aws_signing_helper $HELPER_VERSION"
tmp=$(mktemp)
curl -fsSL --retry 3 -o "$tmp" "$HELPER_URL"
expected=$(curl -fsSL --retry 3 "$HELPER_URL.sha256" | awk '{print $1}')
actual=$(sha256sum "$tmp" | awk '{print $1}')
[ -n "$expected" ] && [ "$expected" = "$actual" ] || { rm -f "$tmp"; die "Checksum mismatch for aws_signing_helper."; }
install -m 755 "$tmp" "$HELPER"
rm -f "$tmp"

log "Writing $AWS_DIR/config (profile 'host')"
cat > "$AWS_DIR/config" <<EOF
# Written by setup_aws_identity.sh. Used by tiosvm-metadata (profile "host").
[profile host]
region = $REGION
credential_process = $HELPER credential-process --certificate $CERT --private-key $KEY --trust-anchor-arn $TRUST_ANCHOR_ARN --profile-arn $PROFILE_ARN --role-arn $ROLE_ARN
EOF

# Only root and the metadata service can read the identity
chown root:"$SERVICE_USER" "$AWS_DIR" "$AWS_DIR/config" "$CERT" "$KEY"
chmod 750 "$AWS_DIR"
chmod 640 "$AWS_DIR/config" "$CERT" "$KEY"

log "Testing: who is the host in AWS?"
run_as_service() {
  sudo -u "$SERVICE_USER" env AWS_CONFIG_FILE="$AWS_DIR/config" \
    AWS_SHARED_CREDENTIALS_FILE="$AWS_DIR/credentials" python3 -c "$1"
}
run_as_service "import boto3; print(boto3.Session(profile_name='host').client('sts', region_name='$REGION').get_caller_identity()['Arn'])" \
  || die "The host could not get its AWS identity. Check the ARNs, the trust anchor and the role's trust policy."

if [ -n "$TEST_ROLE" ]; then
  log "Testing: can the host get credentials for $TEST_ROLE?"
  account=$(cut -d: -f5 <<< "$ROLE_ARN")
  run_as_service "
import boto3
sts = boto3.Session(profile_name='host').client('sts', region_name='$REGION')
c = sts.assume_role(RoleArn='arn:aws:iam::$account:role/$TEST_ROLE', RoleSessionName='setup-test', DurationSeconds=900)
print('OK, credentials until', c['Credentials']['Expiration'])" \
    || die "The host could not assume $TEST_ROLE. Check that role's trust policy and TiosOnpremKvmHost's permissions."
fi

systemctl restart tiosvm-metadata.service
log "Done. VMs launched with --iam-role now get credentials from 169.254.169.254."
