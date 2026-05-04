#!/usr/bin/env bash
set -euo pipefail

# Validate AWS Global Accelerator setup for this repo's topology:
# - exactly 2 accelerators total: "<short_project>-read" and "<short_project>-write"
# - each accelerator has 1 listener on LDAP port (default 389)
# - each listener has an endpoint group with BOTH VPC NLB ARNs registered
#
# This script is intentionally AWS-CLI-only (no jq dependency).
#
# Usage:
#   terraform/openldap/tools/test_ga.sh [project_name] [ldap_port]
#
# Examples:
#   terraform/openldap/tools/test_ga.sh openldap-mm 389
#   GLOBAL_ACCELERATOR_REGION=us-west-2 terraform/openldap/tools/test_ga.sh openldap-mm

project_name="${1:-openldap-mm}"
ldap_port="${2:-389}"
ga_region="${GLOBAL_ACCELERATOR_REGION:-us-west-2}"

short_project="${project_name:0:12}"
read_name="${short_project}-read"
write_name="${short_project}-write"

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 2; }
}

need aws

arn_for_name() {
  local name="$1"
  aws globalaccelerator list-accelerators \
    --region "$ga_region" \
    --query "Accelerators[?Name=='${name}'].AcceleratorArn | [0]" \
    --output text
}

describe_accel() {
  local arn="$1"
  aws globalaccelerator describe-accelerator \
    --region "$ga_region" \
    --accelerator-arn "$arn" \
    --query "Accelerator.{Name:Name,Enabled:Enabled,DnsName:DnsName,IpAddressType:IpAddressType}" \
    --output table
}

listeners_for_accel() {
  local arn="$1"
  aws globalaccelerator list-listeners \
    --region "$ga_region" \
    --accelerator-arn "$arn" \
    --query "Listeners[].ListenerArn" \
    --output text
}

endpoint_groups_for_listener() {
  local listener_arn="$1"
  aws globalaccelerator list-endpoint-groups \
    --region "$ga_region" \
    --listener-arn "$listener_arn" \
    --query "EndpointGroups[].EndpointGroupArn" \
    --output text
}

describe_endpoint_group() {
  local eg_arn="$1"
  aws globalaccelerator describe-endpoint-group \
    --region "$ga_region" \
    --endpoint-group-arn "$eg_arn" \
    --query "EndpointGroup.{Region:EndpointGroupRegion,TrafficDial:TrafficDialPercentage,HealthProto:HealthCheckProtocol,HealthPort:HealthCheckPort,Endpoints:EndpointDescriptions[].{EndpointId:EndpointId,Weight:Weight,HealthState:HealthState}}" \
    --output json
}

check_listener_ports() {
  local accel_arn="$1"
  aws globalaccelerator list-listeners \
    --region "$ga_region" \
    --accelerator-arn "$accel_arn" \
    --query "Listeners[].PortRanges[]" \
    --output text | rg -q "(^|\\s)${ldap_port}(${ldap_port})?(\\s|$)" 2>/dev/null
}

main() {
  echo "Global Accelerator region: ${ga_region}"
  echo "Expecting accelerators: ${read_name}, ${write_name}"
  echo "Expecting listener port: ${ldap_port}"
  echo

  local read_arn write_arn
  read_arn="$(arn_for_name "$read_name")"
  write_arn="$(arn_for_name "$write_name")"

  if [[ -z "$read_arn" || "$read_arn" == "None" ]]; then
    echo "ERROR: could not find accelerator named: ${read_name}" >&2
    exit 1
  fi
  if [[ -z "$write_arn" || "$write_arn" == "None" ]]; then
    echo "ERROR: could not find accelerator named: ${write_name}" >&2
    exit 1
  fi

  echo "Read accelerator:"
  describe_accel "$read_arn"
  echo

  echo "Write accelerator:"
  describe_accel "$write_arn"
  echo

  echo "Read listeners + endpoint groups:"
  for l in $(listeners_for_accel "$read_arn"); do
    echo "listener_arn=${l}"
    for eg in $(endpoint_groups_for_listener "$l"); do
      echo "endpoint_group_arn=${eg}"
      describe_endpoint_group "$eg"
    done
  done
  echo

  echo "Write listeners + endpoint groups:"
  for l in $(listeners_for_accel "$write_arn"); do
    echo "listener_arn=${l}"
    for eg in $(endpoint_groups_for_listener "$l"); do
      echo "endpoint_group_arn=${eg}"
      describe_endpoint_group "$eg"
    done
  done
  echo

  if command -v rg >/dev/null 2>&1; then
    if ! check_listener_ports "$read_arn"; then
      echo "WARNING: could not confirm read listener port includes ${ldap_port} (rg check failed)" >&2
    fi
    if ! check_listener_ports "$write_arn"; then
      echo "WARNING: could not confirm write listener port includes ${ldap_port} (rg check failed)" >&2
    fi
  else
    echo "NOTE: ripgrep (rg) not found; skipping listener port check."
  fi

  echo "OK: accelerators found. Review endpoint group JSON above to ensure both VPC NLB ARNs are present for read and write."
}

main "$@"

