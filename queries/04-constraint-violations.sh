#!/usr/bin/env bash
# Per-namespace violation counts from the Gatekeeper constraints installed by the Azure Policy add-on.
# status.totalViolations is the full count; status.violations is a capped sample.
# enforcementAction: dryrun = Audit, deny = Deny, warn = Warn.
#
# Usage:
#   ./04-constraint-violations.sh                   # reads the cluster in the current kubectl context
#   ./04-constraint-violations.sh constraints.json  # reads a saved export (for example from az aks command invoke)
set -euo pipefail
if [[ $# -ge 1 ]]; then
  DATA=$(cat "$1")
else
  KINDS=$(kubectl api-resources --categories=constraint -o name | paste -sd, -)
  if [[ -z "$KINDS" ]]; then echo "No Gatekeeper constraint kinds found (is the Azure Policy add-on enabled?)"; exit 1; fi
  DATA=$(kubectl get "$KINDS" -o json)
fi

echo "== Totals per constraint"
echo "$DATA" | jq -r '.items[]
  | [.kind, (.spec.enforcementAction // "deny"), (.status.totalViolations // 0),
     (.metadata.annotations["azure-policy-assignment-id"] // "" | split("/") | last),
     (.metadata.annotations["azure-policy-definition-reference-id"] // "")] | @tsv' \
  | sort -t$'\t' -k3 -nr | (echo -e "KIND\tACTION\tVIOLATIONS\tASSIGNMENT\tREFERENCE_ID"; cat) | column -t -s$'\t'

echo; echo "== Sampled violations by namespace and constraint kind"
echo "$DATA" | jq -r '.items[] | .kind as $k | (.status.violations // [])[] | [(.namespace // "(cluster)"), $k] | @tsv' \
  | sort | uniq -c | sort -k2,2 -k1,1nr

echo; echo "== Sampled violations (namespace/kind/name: message)"
echo "$DATA" | jq -r '.items[] | .kind as $k | (.status.violations // [])[] | "\(.namespace // "(cluster)")/\(.kind)/\(.name)\t\($k)\t\(.message)"' \
  | sort | cut -c1-220
