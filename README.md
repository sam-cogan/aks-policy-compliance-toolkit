# AKS Policy Compliance Toolkit

Tools for reviewing the current state of Azure Policy for Azure Kubernetes Service (AKS) and reporting non-compliant workloads, typically before moving policies from Audit to Deny.

- **Current-state queries:** which policies and initiatives are assigned, with what effect, and where they fail.
- **Consolidated non-compliance reporting:** an Azure Monitor workbook, Resource Graph queries and a CSV export. They show non-compliant workloads by namespace, workload, policy and cluster across the whole estate, instead of drilling into each policy, cluster and component in the portal.
- **Custom policy:** blocks NetworkPolicy rules that allow traffic from or to any peer, which would otherwise bypass a default-deny network model.

Everything here is **read-only** against your environment. Nothing changes policy assignments, effects, clusters or workloads. The only resource you can optionally create is the Azure Monitor workbook.

## Contents

```text
toolkit/
├── README.md                              This file
├── LICENSE
├── queries/                               Current-state inventory
│   ├── 01-aks-assignments.kql             Policy and initiative assignments, effects, overrides
│   ├── 02-aks-compliance-by-policy.kql    Cluster-level compliance per assignment and policy
│   ├── 03-aks-noncompliant-components.kql Component-level non-compliance counts per cluster and policy
│   └── 04-constraint-violations.sh        In-cluster Gatekeeper totals (complete counts) for one cluster
├── reporting/                             Consolidated non-compliance reporting
│   ├── workbook/
│   │   ├── main.bicep                     Deploys the Azure Monitor workbook
│   │   └── aks-policy-noncompliance.workbook.json
│   ├── queries/                           Same views as the workbook, as Resource Graph queries
│   │   ├── 05-noncompliance-detail.kql
│   │   ├── 06-noncompliance-by-namespace.kql
│   │   ├── 07-noncompliance-by-workload.kql
│   │   ├── 08-noncompliance-by-policy.kql
│   │   └── 09-noncompliance-by-cluster-policy.kql
│   ├── export/
│   │   └── export-noncompliance.sh        CSV export: whole estate + one file per namespace
│   └── screenshots/                       Workbook example from a test cluster
└── custom-policies/
    └── netpol-no-allow-all/               Custom policy: deny allow-all NetworkPolicy rules
```

## Prerequisites

| Requirement | Needed for |
|---|---|
| **Reader** on the AKS subscriptions, or on the management group above them | All Resource Graph queries, workbook, CSV export |
| **Azure CLI** (current version) with the Resource Graph extension: `az extension add -n resource-graph` | CSV export, running queries from the CLI |
| **jq** | CSV export, kubectl script |
| **kubectl** access to the cluster (Azure Kubernetes Service Cluster User role or equivalent; kubelogin for Entra ID-integrated clusters) | `04-constraint-violations.sh` |
| **Workbook Contributor** (or Contributor) on a resource group | Deploying the workbook only |
| **Bicep CLI** (bundled with Azure CLI) | Deploying the workbook with Bicep |
| **gator** CLI ([Gatekeeper releases](https://github.com/open-policy-agent/gatekeeper/releases)) | Testing the custom policy only |

The shell scripts are bash and run on macOS, Linux, WSL or Azure Cloud Shell. Cloud Shell already has `az`, `jq` and `kubectl`.

## Quick start

1. **See what is assigned:** run `queries/01-aks-assignments.kql` in Resource Graph Explorer.
2. **Get a consolidated view:** deploy the workbook, `az deployment group create -g <resource-group> -f reporting/workbook/main.bicep`, and open it from Monitor → Workbooks.
3. **Export per-team lists:** run `reporting/export/export-noncompliance.sh ./aks-noncompliance`.
4. **Get complete in-cluster counts:** run `queries/04-constraint-violations.sh` against a cluster.

---

## 1. Current-state queries (`queries/`)

Run the `.kql` files in **Azure portal → Resource Graph Explorer**. Set the scope (top-right) to the subscriptions or management group containing the AKS clusters, paste the query, then select **Run query** and **Download formatted results as CSV**.

To run them from the CLI instead, remove the comment lines first:

```bash
az graph query -q "$(grep -v '^//' queries/01-aks-assignments.kql)" --first 1000 -o table
# Scope to a management group:
az graph query -q "$(grep -v '^//' queries/01-aks-assignments.kql)" --management-groups <mg-id> --first 1000 -o table
```

| Query | Returns | Use it to |
|---|---|---|
| `01-aks-assignments.kql` | Every policy and initiative assignment in scope, with enforcement mode, `definitionVersion`, overrides and parameters | Confirm what is assigned where, and whether anything is already set to Deny |
| `02-aks-compliance-by-policy.kql` | Per assignment and policy: how many AKS clusters are evaluated and how many are non-compliant | Find the policies with the widest non-compliance |
| `03-aks-noncompliant-components.kql` | Per cluster, assignment and policy: count of non-compliant pods and other Kubernetes objects, with a sample | Size the remediation work per policy |

### `04-constraint-violations.sh` — in-cluster totals

Azure Policy stores up to 500 non-compliant records per policy per cluster. This script reads the Gatekeeper constraints directly from a cluster, so it gives complete counts.

```bash
az aks get-credentials -g <resource-group> -n <cluster-name>
./queries/04-constraint-violations.sh > <cluster-name>-constraints.txt
```

The output has three sections:

- **Totals per constraint:** constraint kind, enforcement action, total violations, the Azure Policy assignment and the policy reference ID. `dryrun` means Audit and `deny` means Deny.
- **Sampled violations by namespace and constraint kind:** where the violations are.
- **Sampled violations with messages:** namespace, object and the reason it failed.

`status.totalViolations` is the full count. The per-object list in `status.violations` is a sample capped by Gatekeeper.

---

## 2. Consolidated non-compliance reporting (`reporting/`)

The Azure portal shows non-compliance per policy, then per cluster, then per component. These tools consolidate it into one view by namespace, workload and policy across every cluster.

### How it works

- **Source:** Azure Resource Graph `componentpolicystates`, the component-level results reported by the Azure Policy add-on for in-cluster (`Microsoft.Kubernetes.Data`) policies. These are joined to policy assignments and custom definitions to get display names.
- **Workload:** Azure records the pod, not its owner. The workload is inferred from the pod name: CronJob (timestamp suffix), Deployment (ReplicaSet hash), StatefulSet (ordinal), DaemonSet or Job (5-character suffix). Non-pod objects, such as NetworkPolicies, use the object name.
- **Policy name:** built-in definition names are not available in Resource Graph. The queries include a lookup of the 76 built-in in-cluster Kubernetes policies (catalogue as of 29 September 2026). Custom definitions use their display name. Anything else falls back to the initiative reference ID or definition ID.
- **Effect:** taken from the cluster-level policy state, falling back to the assignment's `effect` parameter. It shows `unresolved` where neither is available yet, typically for initiatives assigned at management-group scope whose cluster-level results have not published.
- **Freshness:** results appear roughly 20 minutes after a workload changes (15-minute Gatekeeper audit plus the Azure Policy reporting cycle). Resource Graph holds the latest state only, with no history.
- **System namespaces** are hidden by default: `kube-system`, `gatekeeper-system`, `azure-arc`, `azure-extensions-usage-system` and `flux-system`.

### Workbook (`reporting/workbook/`)

**Deploy with Bicep:**

```bash
az deployment group create -g <resource-group> -f reporting/workbook/main.bicep
# Optional parameters: -p displayName="AKS policy non-compliance" location=<region>
```

**Or import manually:** Azure portal → **Monitor → Workbooks → New → Advanced editor** (the `</>` icon). Replace the content with `aks-policy-noncompliance.workbook.json`, then select **Apply** and **Save**.

Open it from **Monitor → Workbooks** or from the resource group.

| Tab | Shows |
|---|---|
| **Overview** | Totals (non-compliant components, workloads, namespaces, clusters, policies), top 20 namespaces, top 15 policies, cluster × policy heat map |
| **By namespace** | One row per namespace with counts and the policies violated. Select a row to list its workloads |
| **By workload** | One row per workload with the list of policies it violates |
| **By policy** | One row per policy with the number of workloads, namespaces and clusters affected. Select a row to list the workloads |
| **All findings** | Every non-compliant component and policy, searchable |
| **Cluster level** | Non-compliant AKS cluster resources by assignment, including cluster-configuration policies |

**Filters:** subscriptions, clusters, namespaces, policies, effect, hide system namespaces, and the list of system namespaces (editable). Every grid has a search box and **Export to Excel** (the download icon).

Anyone who can read the AKS subscriptions can use the workbook. Nothing else needs deploying.

### Resource Graph queries (`reporting/queries/`)

The same views as the workbook, for Resource Graph Explorer, dashboards or scripting. Run them as described in section 1. System namespaces are excluded by the line starting `| where namespace !in~`; delete it to include them.

| Query | One row per |
|---|---|
| `05-noncompliance-detail.kql` | Non-compliant component per policy (cluster, namespace, workload, kind, component, policy, effect, assignment) |
| `06-noncompliance-by-namespace.kql` | Namespace |
| `07-noncompliance-by-workload.kql` | Workload, with the list of policies it violates |
| `08-noncompliance-by-policy.kql` | Policy |
| `09-noncompliance-by-cluster-policy.kql` | Cluster and policy |

Resource Graph Explorer returns up to 1,000 rows per page. Use the export script for larger results.

### CSV export (`reporting/export/export-noncompliance.sh`)

Pages through all results and writes CSV files.

```bash
chmod +x reporting/export/export-noncompliance.sh
az login
az account set --subscription <any-subscription-in-the-tenant>

# All subscriptions available to your az CLI context:
./reporting/export/export-noncompliance.sh ./aks-noncompliance

# Or scoped to a management group:
./reporting/export/export-noncompliance.sh ./aks-noncompliance <management-group-id>
```

Output:

```text
aks-noncompliance/
├── all.csv                 Every non-compliant component per policy, whole estate
└── by-namespace/
    ├── team-a.csv          One file per namespace, for sending to the owning team
    └── ...
```

Columns: `cluster, namespace, workloadKind, workload, objectKind, component, policy, effect, assignment, initiative, lastEvaluated, subscriptionId`.

It runs unattended, so it can be scheduled in a pipeline (for example Azure DevOps with an Azure CLI task) to produce weekly per-team remediation lists.

### Things to be aware of

- **Duplicate rows:** if the same control is assigned twice, for example your guardrail initiative and Defender for Cloud's Microsoft cloud security benchmark, each pod appears once per assignment. Use the Assignment column or filter to separate them.
- **500-record cap:** Azure Policy stores up to 500 non-compliant records per policy per cluster. Use `04-constraint-violations.sh` for complete counts on large clusters.
- **Pod name inference:** pods created directly, or with unusual naming, show as kind `Pod` under their own name.
- **Timing:** allow about 20 minutes after deploying or changing workloads before expecting the reports to reflect them.

---

## 3. Custom policy: deny allow-all NetworkPolicies (`custom-policies/netpol-no-allow-all/`)

Assign it with `effect: Audit` first and review the results before switching to Deny.

It flags or denies NetworkPolicy rules that match every peer, which would bypass a default-deny network model:

| Flagged | Allowed |
|---|---|
| `ingress: [{}]` or `egress: [{}]` (rule with no `from`/`to`) | Default-deny policies (no rules) |
| Empty `from`/`to` list | Peers scoped with `namespaceSelector` and `podSelector` labels |
| `namespaceSelector: {}` without a `podSelector` | Scoped CIDRs such as `10.20.0.0/16` |
| `ipBlock` of `0.0.0.0/0` or `::/0` | Open egress restricted to listed ports (default: DNS on 53) |

| File | Purpose |
|---|---|
| `template.yaml` | Gatekeeper ConstraintTemplate (Rego) |
| `constraint.yaml` | Example constraint, used by the tests |
| `azurepolicy.json` | Azure Policy custom definition (`Microsoft.Kubernetes.Data` mode, template embedded as Base64) |
| `suite.yaml`, `tests/` | gator test suite: 7 cases, including an allow-all policy in a system namespace |

**Test locally:**

```bash
cd custom-policies/netpol-no-allow-all
gator verify .
```

**Create the definition (when agreed):**

```bash
jq '.properties.policyRule' azurepolicy.json > rule.json
jq '.properties.parameters' azurepolicy.json > params.json
az policy definition create -n netpol-no-allow-all \
  --display-name "Kubernetes NetworkPolicies should not allow traffic from or to any peer" \
  --mode Microsoft.Kubernetes.Data --rules rule.json --params params.json \
  --management-group <mg-id>   # or --subscription <sub-id>
```

Assign it with `effect: Audit` first. Parameters: `effect`, `excludedNamespaces`, `namespaces`, `labelSelector`, `warn`, `allowPortScopedOpenEgress` (default `true`) and `allowedOpenEgressPorts` (default `[53]`).

---

## Validation

In September 2026 the toolkit was tested end to end on an AKS 1.35 cluster (Azure CNI Overlay with Cilium, Azure Policy add-on with Gatekeeper 3.23). The cluster ran deliberately non-compliant Deployment, StatefulSet, DaemonSet, CronJob, Pod and NetworkPolicy workloads. All queries, the workbook, the CSV export and the kubectl script returned the expected results. The custom definition was created in Azure, installed by the add-on, and flagged both test allow-all NetworkPolicies. See `reporting/screenshots/overview.png`.

## References

- [Azure Policy for Kubernetes](https://learn.microsoft.com/azure/governance/policy/concepts/policy-for-kubernetes)
- [Built-in policies for AKS](https://learn.microsoft.com/azure/aks/policy-reference)
- [Azure Resource Graph Explorer](https://learn.microsoft.com/azure/governance/resource-graph/first-query-portal)
- [Azure Monitor workbooks](https://learn.microsoft.com/azure/azure-monitor/visualize/workbooks-overview)
- [Gatekeeper gator CLI](https://open-policy-agent.github.io/gatekeeper/website/docs/gator/)

## Licence

MIT. See [LICENSE](LICENSE). Provided as-is, with no warranty. This is not an official Microsoft product or support offering. Test in a non-production environment first.
