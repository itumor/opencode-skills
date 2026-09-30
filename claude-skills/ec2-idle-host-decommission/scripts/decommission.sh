#!/usr/bin/env bash
# Snapshot -> terminate -> back up + delete Route53 A records -> verify.
# Usage: decommission.sh <admin-profile> <region> <instance-id> <ticket> [--apply]
# Default = dry run (prints what it would do). Instance must already be STOPPED
# (stop first, wait for complaints, then run this).
# ponytail: only deletes A records whose sole value == instance private IP; CNAME/alias left for a human.
set -euo pipefail
[ $# -ge 4 ] || { echo "usage: $0 <profile> <region> <instance-id> <ticket> [--apply]"; exit 2; }
P=$1 R=$2 I=$3 T=$4 GO=${5:-}
A=(aws --profile "$P" --region "$R")
OUT=${DECOM_OUT:-$HOME/.claude/decommission-backups}/$T; mkdir -p "$OUT"
DEL=$(date -u -v+30d +%Y-%m-%d 2>/dev/null || date -u -d '+30 days' +%Y-%m-%d)
run() { if [ "$GO" = --apply ]; then "$@"; else echo "DRY: $*"; fi; }

read -r STATE NAME IP < <("${A[@]}" ec2 describe-instances --instance-ids "$I" \
  --query 'Reservations[0].Instances[0].[State.Name,Tags[?Key==`Name`]|[0].Value,PrivateIpAddress]' --output text)
echo "## $NAME $I $STATE ip=$IP  (backups -> $OUT)"
[ "$STATE" = stopped ] || { echo "ABORT: instance is $STATE, stop it first"; exit 1; }
"${A[@]}" ec2 describe-instances --instance-ids "$I" --output json > "$OUT/instance.json"

echo "## 1 snapshot every volume (Ticket/Host/DeleteAfter=$DEL)"
for v in $("${A[@]}" ec2 describe-instances --instance-ids "$I" --query 'Reservations[0].Instances[0].BlockDeviceMappings[].Ebs.VolumeId' --output text); do
  if [ "$GO" = --apply ]; then
    s=$("${A[@]}" ec2 create-snapshot --volume-id "$v" --description "$T pre-terminate $NAME" \
      --tag-specifications "ResourceType=snapshot,Tags=[{Key=Ticket,Value=$T},{Key=Host,Value=$NAME},{Key=DeleteAfter,Value=$DEL}]" \
      --query SnapshotId --output text)
    echo "$v -> $s (waiting)"; "${A[@]}" ec2 wait snapshot-completed --snapshot-ids "$s"; echo "$s completed" | tee -a "$OUT/snapshots.txt"
  else echo "DRY: snapshot $v"; fi
done

echo "## 2 terminate"
run "${A[@]}" ec2 terminate-instances --instance-ids "$I" --query 'TerminatingInstances[0].CurrentState.Name' --output text
[ "$GO" = --apply ] && "${A[@]}" ec2 wait instance-terminated --instance-ids "$I"

echo "## 3 Route53 A records == $IP"
for z in $("${A[@]}" route53 list-hosted-zones --query 'HostedZones[].Id' --output text); do
  "${A[@]}" route53 list-resource-record-sets --hosted-zone-id "$z" \
    --query "ResourceRecordSets[?Type=='A' && length(ResourceRecords||\`[]\`)==\`1\` && ResourceRecords[0].Value=='$IP']" --output json > "$OUT/rec.json"
  n=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))))' "$OUT/rec.json")
  [ "$n" = 0 ] && continue
  zid=${z##*/}; cp "$OUT/rec.json" "$OUT/r53_${zid}.json"; cat "$OUT/rec.json"
  python3 -c 'import json,sys;r=json.load(open(sys.argv[1]));json.dump({"Comment":sys.argv[3],"Changes":[{"Action":"DELETE","ResourceRecordSet":x} for x in r]},open(sys.argv[2],"w"))' \
    "$OUT/rec.json" "$OUT/change_${zid}.json" "$T remove record for decommissioned $NAME"
  run "${A[@]}" route53 change-resource-record-sets --hosted-zone-id "$z" --change-batch "file://$OUT/change_${zid}.json" --query ChangeInfo.Status --output text
done

echo "## 4 verify"
"${A[@]}" ec2 describe-instances --instance-ids "$I" --query 'Reservations[0].Instances[0].State.Name' --output text
echo "Rollback: restore snapshot(s) in $OUT/snapshots.txt, re-create A record from $OUT/r53_*.json (Action=CREATE)."
