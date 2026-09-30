#!/usr/bin/env bash
# Read-only usage evidence for one EC2 instance before decommission.
# Usage: evidence.sh <profile> <region> <instance-id>    (ReadOnly profile is enough)
set -uo pipefail
[ $# -eq 3 ] || { echo "usage: $0 <profile> <region> <instance-id>"; exit 2; }
P=$1 R=$2 I=$3
A=(aws --profile "$P" --region "$R")
S=$(date -u -v-90d +%Y-%m-%dT00:00:00Z 2>/dev/null || date -u -d '90 days ago' +%Y-%m-%dT00:00:00Z)
E=$(date -u +%Y-%m-%dT%H:%M:%SZ)

read -r NAME IP STATE TYPE LAUNCH < <("${A[@]}" ec2 describe-instances --instance-ids "$I" \
  --query 'Reservations[0].Instances[0].[Tags[?Key==`Name`]|[0].Value,PrivateIpAddress,State.Name,InstanceType,LaunchTime]' --output text) \
  || { echo "describe-instances failed (SSO expired? wrong region?)"; exit 1; }
echo "## $NAME $I $STATE $TYPE ip=$IP launched=$LAUNCH"
VOLS=$("${A[@]}" ec2 describe-instances --instance-ids "$I" --query 'Reservations[0].Instances[0].BlockDeviceMappings[].Ebs.VolumeId' --output text)
SGS=$("${A[@]}" ec2 describe-instances --instance-ids "$I" --query 'Reservations[0].Instances[0].SecurityGroups[].GroupId' --output text)

echo "## volumes (size type encrypted) + existing snapshots"
for v in $VOLS; do
  "${A[@]}" ec2 describe-volumes --volume-ids "$v" --query 'Volumes[0].[VolumeId,Size,VolumeType,Encrypted]' --output text
  "${A[@]}" ec2 describe-snapshots --owner-ids self --filters Name=volume-id,Values="$v" --query 'Snapshots[].[SnapshotId,StartTime,Tags[?Key==`Ticket`]|[0].Value]' --output text
done
echo "## EIP"; "${A[@]}" ec2 describe-addresses --filters Name=instance-id,Values="$I" --output text
echo "## target groups containing instance"
for a in $("${A[@]}" elbv2 describe-target-groups --query 'TargetGroups[].TargetGroupArn' --output text); do
  "${A[@]}" elbv2 describe-target-health --target-group-arn "$a" --query "TargetHealthDescriptions[?Target.Id=='$I'].Target.Id" --output text | sed "s|^|$a |"
done
echo "## SGs shared with other ENIs (shared => never delete SG)"
for s in $SGS; do echo "$s:"; "${A[@]}" ec2 describe-network-interfaces --filters Name=group-id,Values="$s" --query 'NetworkInterfaces[].[Attachment.InstanceId,Description]' --output text; done
echo "## CloudTrail (90d max; AssumeRole-only = no humans)"
"${A[@]}" cloudtrail lookup-events --lookup-attributes AttributeKey=ResourceName,AttributeValue="$I" --max-results 50 \
  --query 'Events[].[EventTime,EventName,Username]' --output text | grep -v AssumeRole | head -20
echo "## SSM sessions (history is GC'd ~30d)"
"${A[@]}" ssm describe-sessions --state History --filters key=Target,value="$I" --query 'Sessions[].[Owner,StartDate]' --output text
echo "## Route53 records by IP or name (private zones too)"
for z in $("${A[@]}" route53 list-hosted-zones --query 'HostedZones[].Id' --output text); do
  "${A[@]}" route53 list-resource-record-sets --hosted-zone-id "$z" \
    --query "ResourceRecordSets[?contains(to_string(ResourceRecords),'$IP') || contains(Name,'$NAME')].[Name,Type,ResourceRecords[0].Value]" --output text | sed "s|^|$z |"
done
echo "## 90d daily metrics: top-5 days + last 7"
for m in CPUUtilization NetworkIn NetworkOut; do
  st=Sum; [ $m = CPUUtilization ] && st=Average
  out=$("${A[@]}" cloudwatch get-metric-statistics --namespace AWS/EC2 --metric-name $m --dimensions Name=InstanceId,Value="$I" \
    --start-time "$S" --end-time "$E" --period 86400 --statistics $st --query "sort_by(Datapoints,&Timestamp)[].[Timestamp,$st]" --output text)
  echo "-- $m ($st) top:"; sort -k2 -nr <<<"$out" | head -5; echo "-- last 7:"; tail -7 <<<"$out"
done
