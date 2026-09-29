# Reference guide

What each file in the toolkit does, how the reporting works, the output formats, and example queries for going further. For step-by-step instructions, see [How to run the toolkit (bash)](how-to-run.md) or [How to run the toolkit (PowerShell)](how-to-run-powershell.md).

## Contents

- [Repository layout](#repository-layout)
- [Current-state queries](#current-state-queries)
- [In-cluster counts script](#in-cluster-counts-script)
- [PowerShell query runner](#powershell-query-runner)
- [How the non-compliance reporting works](#how-the-non-compliance-reporting-works)
- [Workbook](#workbook)
- [Reporting queries](#reporting-queries)
- [CSV export](#csv-export)
- [Example queries](#example-queries)
- [Custom policy: deny allow-all NetworkPolicies](#custom-policy-deny-allow-all-networkpolicies)
- [Limitations and caveats](#limitations-and-caveats)
- [Validation](#validation)
- [Further reading](#further-reading)

---

## Repository layout

```text
.
├── README.md                                Overview and quick start
├── docs/
│   ├── how-to-run.md                        Step-by-step instructions (bash)
│   ├── how-to-run-powershell.md             Step-by-step instructions (PowerShell)
│   └── reference.md                         This guide
├── queries/                                 Current-state inventory
│   ├── 01-aks-assignments.kql               Policy and initiative assignments, effects, overrides
│   ├── 02-aks-compliance-by-policy.kql      Cluster-level compliance per assignment and policy
│   ├── 03-aks-noncompliant-components.kql   Component-level non-compliance counts per cluster and policy
│   ├── 04-constraint-violations.sh          Complete in-cluster Gatekeeper counts for one cluster (bash)
│   ├── 04-constraint-violations.ps1         The same, in PowerShell
│   └── Invoke-GraphQuery.ps1                PowerShell runner for any .kql file (paging, CSV output)
├── reporting/                               Consolidated non-compliance reporting
│   ├── workbook/
│   │   ├── main.bicep                       Deploys the Azure Monitor workbook
│   │   ├── main.json                        Compiled ARM template of main.bicep (no Bicep install needed)
│   │   └── aks-policy-noncompliance.workbook.json
│   ├── queries/                             The workbook views as Resource Graph queries
│   │   ├── 05-noncompliance-detail.kql
│   │   ├── 06-noncompliance-by-namespace.kql
│   │   ├── 07-noncompliance-by-workload.kql
│   │   ├── 08-noncompliance-by-policy.kql
│   │   └── 09-noncompliance-by-cluster-policy.kql
│   ├── export/
│   │   ├── export-noncompliance.sh          CSV export: whole estate + one file per namespace (bash)
│   │   └── Export-NonCompliance.ps1         The same, in PowerShell
│   └── screenshots/                         Workbook examples from a test cluster
└── custom-policies/
    └── netpol-no-allow-all/                 Custom policy: deny allow-all NetworkPolicy rules
```

Every file is read-only against Azure and your clusters, except `main.bicep` / `main.json` (create the workbook) and the custom policy definition when you choose to create it.

### Bash and PowerShell

The bash scripts use the Azure CLI (`az graph query`) and `jq`. The PowerShell scripts use the Az PowerShell modules (`Search-AzGraph` from Az.ResourceGraph), so on Windows they avoid the Azure CLI's quoting problems with multi-line queries. Both run the same `.kql` files and produce the same CSV columns and in-cluster output.

| Task | Bash | PowerShell 7 |
|---|---|---|
| Run a query file | `az graph query -q "$(grep -v '^//' <file>.kql)"` | `./queries/Invoke-GraphQuery.ps1 -QueryFile <file>.kql [-OutFile x.csv]` |
| CSV export | `./reporting/export/export-noncompliance.sh <dir> [mg-id]` | `./reporting/export/Export-NonCompliance.ps1 -OutputPath <dir> [-ManagementGroup <id>] [-IncludeSystemNamespaces]` |
| In-cluster counts | `./queries/04-constraint-violations.sh [file.json]` | `./queries/04-constraint-violations.ps1 [-InputFile file.json]` |
| Deploy workbook | `az deployment group create -g <rg> -f reporting/workbook/main.bicep` | `New-AzResourceGroupDeployment -ResourceGroupName <rg> -TemplateFile ./reporting/workbook/main.json` |

---

## Current-state queries

Azure Resource Graph queries in `queries/`. Run them in Resource Graph Explorer, with `az graph query` ([bash step 3](how-to-run.md#step-3--inventory-policy-assignments)) or with `Invoke-GraphQuery.ps1` ([PowerShell step 3](how-to-run-powershell.md#step-3--inventory-policy-assignments)).

### `01-aks-assignments.kql`

Lists every policy and initiative assignment visible in the query scope.

| Column | Meaning |
|---|---|
| `assignment` | Assignment name (resource name) |
| `displayName` | Assignment display name |
| `scope` | Management group, subscription or resource group it's assigned at |
| `definition` | Policy or initiative definition ID |
| `enforcementMode` | `Default` (effects apply) or `DoNotEnforce` (nothing is denied; compliance still reported) |
| `definitionVersion` | Pinned definition version, if set |
| `overrides` | Effect overrides, for example individual policies promoted to Deny |
| `parameters` | Assignment parameters, including `effect`, `excludedNamespaces` and allowed values |

It lists all assignments, not only AKS ones. Filter it to Kubernetes-related assignments with the approach in [example queries](#example-queries).

### `02-aks-compliance-by-policy.kql`

One row per assignment and policy that evaluates AKS clusters, with the number of clusters evaluated (`clusters`) and non-compliant (`nonCompliantClusters`). For Kubernetes policies, a cluster is non-compliant when any object inside it is non-compliant.

### `03-aks-noncompliant-components.kql`

One row per cluster, assignment, policy and component type (for example `Pod` or `NetworkPolicy`), with the number of non-compliant components and one sample (`namespace/name`). Assignment and definition are shown by name or ID, because component results carry IDs only.

---

## In-cluster counts script

`queries/04-constraint-violations.sh` (bash, needs `jq`) and `queries/04-constraint-violations.ps1` (PowerShell 7) read the Gatekeeper constraints that the Azure Policy add-on installs on a cluster.

```text
./04-constraint-violations.sh                          # cluster in the current kubectl context
./04-constraint-violations.sh constraints.json         # saved export, for example from az aks command invoke
./04-constraint-violations.ps1                         # PowerShell, current kubectl context
./04-constraint-violations.ps1 -InputFile constraints.json
```

| Section | Content |
|---|---|
| Totals per constraint | `KIND` (constraint template), `ACTION` (`dryrun` = Audit, `deny` = Deny, `warn` = Warn), `VIOLATIONS` (complete count from `status.totalViolations`), `ASSIGNMENT` (Azure Policy assignment name), `REFERENCE_ID` (policy reference within an initiative) |
| Sampled violations by namespace and constraint kind | Count of sampled violations per namespace and constraint |
| Sampled violations | `namespace/kind/name`, constraint, and the violation message |

The sampled lists come from `status.violations`, which Gatekeeper caps. Use `VIOLATIONS` for totals.

It discovers constraint kinds with `kubectl api-resources --categories=constraint`. It doesn't use `kubectl get constraints`, because on current add-on versions that name also matches the ConstraintTemplate resource and returns templates instead of constraints.

---

## PowerShell query runner

`queries/Invoke-GraphQuery.ps1` runs any toolkit `.kql` file with `Search-AzGraph`.

| Parameter | Meaning |
|---|---|
| `-QueryFile` | Path to the `.kql` file (required). `//` comment lines are removed before running. |
| `-ManagementGroup` | Management group ID(s) to query |
| `-Subscription` | Subscription ID(s) to query. With neither, the subscriptions in the current Az context are used. |
| `-OutFile` | Write CSV (UTF-8). Without it, rows are returned to the pipeline for `Format-Table`, `Where-Object` and so on. |

It pages through all results with skip tokens, writes nested values (for example `parameters`, `overrides`) as compact JSON text, and writes timestamps as ISO 8601 UTC. It requires the Az.Accounts and Az.ResourceGraph modules and a signed-in context (`Connect-AzAccount`).

---

## How the non-compliance reporting works

The workbook, reporting queries and CSV export share the same base query.

| Aspect | How it's derived |
|---|---|
| **Source** | Azure Resource Graph `policyresources`, type `microsoft.policyinsights/componentpolicystates`: the per-object results the Azure Policy add-on reports for Kubernetes (`Microsoft.Kubernetes.Data`) policies. Only `NonCompliant` records are used. |
| **Cluster** | Parsed from the component's `resourceId` |
| **Namespace and object** | Parsed from `componentId`, which has the form `namespace/name`. Cluster-scoped objects show as `(cluster-scoped)`. |
| **Object kind** | `componentType`, for example `Pod` or `NetworkPolicy` |
| **Workload** | Azure records the pod, not the owning workload, so it is inferred from the pod name, in this order: **CronJob** (`<name>-<8+ digit timestamp>-<5 chars>`), **Deployment** (`<name>-<ReplicaSet hash>-<5 chars>`), **StatefulSet** (`<name>-<ordinal>`), **DaemonSet / Job** (`<name>-<5 chars>`), otherwise **Pod**. Non-pod objects use their own name. |
| **Policy name** | 1. the custom definition's display name (joined from `microsoft.authorization/policydefinitions`); 2. a built-in lookup of the 76 in-cluster Kubernetes policies (catalogue as of September 2026), because built-in display names aren't available in Resource Graph; 3. the initiative reference ID; 4. the definition ID |
| **Assignment** | Display name joined from `microsoft.authorization/policyassignments`, or the assignment name parsed from its ID |
| **Effect** | 1. `DoNotEnforce` assignments show `audit (DoNotEnforce)`; 2. the cluster-level policy state's `policyDefinitionAction`; 3. the assignment's `effect` parameter; 4. otherwise `unresolved` |
| **System namespaces** | `kube-system`, `gatekeeper-system`, `azure-arc`, `azure-extensions-usage-system` and `flux-system` are excluded by default |

---

## Workbook

`reporting/workbook/aks-policy-noncompliance.workbook.json`, deployed by `main.bicep` (or its compiled ARM template `main.json`) as a shared workbook (`Microsoft.Insights/workbooks`, category `workbook`, source `azure monitor`). All queries run against Azure Resource Graph with the permissions of the person viewing it.

### Parameters

| Parameter | Default | Effect |
|---|---|---|
| Subscriptions | All | Subscriptions queried |
| Clusters | All | Filter by AKS cluster name |
| Namespaces | All | Filter by namespace (lists namespaces with findings) |
| Policies | All | Filter by policy name |
| Effect | All | `audit`, `deny`, `audit (DoNotEnforce)`, `unresolved` |
| Hide system namespaces | Yes | Excludes the namespaces in *System namespaces* |
| System namespaces | See above | Comma-separated, editable |

### Tabs

| Tab | Visuals | Interaction |
|---|---|---|
| Overview | Totals tiles; top 20 namespaces; top 15 policies; cluster × policy heat map | — |
| By namespace | Namespaces with non-compliant count, workloads, policies violated, clusters, policy list | Select a row to list that namespace's workloads |
| By workload | Workload, kind, namespace, cluster, pods, policies violated, policy list, effects | Search |
| By policy | Policy, non-compliant count, workloads, namespaces, clusters, effects, assignments | Select a row to list the affected workloads |
| All findings | Every component and policy | Search |
| Cluster level | Non-compliant AKS cluster resources per assignment and effect, with the policies failed | Includes cluster-configuration policies (Indexed mode) |

Every grid supports search, column sorting and export to Excel.

### Customising

Open the workbook, select **Edit**, then the **Advanced Editor** (`</>`) to change queries or layout. The hidden `PolicyNames` parameter holds the built-in policy name lookup. Update it if Microsoft adds new built-in Kubernetes policies and you want their display names; until then they show by initiative reference ID or definition ID.

---

## Reporting queries

The workbook's views as standalone Resource Graph queries in `reporting/queries/`, for Resource Graph Explorer, dashboards and scripts. System namespaces are excluded by the line starting `| where namespace !in~`; delete it to include them.

| Query | One row per | Key columns |
|---|---|---|
| `05-noncompliance-detail.kql` | Non-compliant component per policy | cluster, namespace, workloadKind, workload, objectKind, component, policy, effect, initiative, assignment, lastEvaluated |
| `06-noncompliance-by-namespace.kql` | Namespace | violations, workloads, policiesViolated, clusters, policies, denyEffect |
| `07-noncompliance-by-workload.kql` | Workload | cluster, namespace, workloadKind, workload, policiesViolated, pods, policies, effects |
| `08-noncompliance-by-policy.kql` | Policy | violations, workloads, namespaces, clusters, effects, assignments |
| `09-noncompliance-by-cluster-policy.kql` | Cluster and policy | violations, workloads, namespaces |

Resource Graph Explorer and `az graph query` return up to 1,000 rows per request. Use the CSV export for larger result sets.

To pin a query to an Azure dashboard, run it in Resource Graph Explorer and select **Pin to dashboard**.

---

## CSV export

`reporting/export/export-noncompliance.sh [output-dir] [management-group-id]` (bash) and `reporting/export/Export-NonCompliance.ps1 -OutputPath <dir> [-ManagementGroup <id>] [-Subscription <id>] [-IncludeSystemNamespaces]` (PowerShell) run the detail query, page through all results, and write:

```text
<output-dir>/
├── all.csv
└── by-namespace/<namespace>.csv
```

| Column | Meaning |
|---|---|
| `cluster` | AKS cluster name |
| `namespace` | Namespace, or `(cluster-scoped)` |
| `workloadKind` | Deployment, StatefulSet, DaemonSet / Job, CronJob or Pod for pods; otherwise the object kind |
| `workload` | Inferred workload name, or object name for non-pod objects |
| `objectKind` | Kubernetes kind of the non-compliant object |
| `component` | Object name, for example the pod name |
| `policy` | Policy display name, reference ID or definition ID (see [how it works](#how-the-non-compliance-reporting-works)) |
| `effect` | `audit`, `deny`, `audit (DoNotEnforce)` or `unresolved` |
| `assignment` | Assignment display name |
| `initiative` | Initiative (policy set) definition ID, if the policy came from an initiative |
| `lastEvaluated` | When the component was last evaluated |
| `subscriptionId` | Subscription of the cluster |

Both scripts need no interaction, so they can run on a schedule, for example in an Azure DevOps or GitHub Actions pipeline (Azure CLI or Azure PowerShell task) with a service principal or managed identity with Reader. The output can then be published as a pipeline artifact for owning teams.

---

## Example queries

Run these in Resource Graph Explorer, with `az graph query` (strip `//` comment lines for the CLI), or save them as a `.kql` file and run them with `Invoke-GraphQuery.ps1`. In PowerShell you can also pass a query directly: `Search-AzGraph -Query @'...'@ -First 1000`.

### Filter the detail query

Append a filter line to the end of `05-noncompliance-detail.kql`:

```kusto
| where namespace == 'team-a'                              // one namespace
| where cluster == 'aks-prod-01'                           // one cluster
| where policy has 'privileged'                            // one control
| where effect == 'deny'                                   // only policies already enforcing
| where workload == 'web-api' and namespace == 'team-a'    // one workload
```

### Clusters and Azure Policy add-on status

```kusto
resources
| where type =~ 'microsoft.containerservice/managedclusters'
| project cluster = name, resourceGroup, subscriptionId, location,
          kubernetesVersion = tostring(properties.kubernetesVersion),
          policyAddon = coalesce(tobool(properties.addonProfiles.azurepolicy.enabled), false)
| order by policyAddon asc, cluster asc
```

### Which assignments produce the findings (duplicate evaluation check)

```kusto
policyresources
| where type =~ 'microsoft.policyinsights/componentpolicystates'
| extend p = properties
| where tostring(p.complianceState) =~ 'NonCompliant'
| summarize components = count(), clusters = dcount(tostring(p.resourceId))
    by assignment = extract('[^/]+$', 0, tostring(p.policyAssignmentId)),
       assignmentScope = tostring(split(tostring(p.policyAssignmentId), '/providers/Microsoft.Authorization')[0])
| order by components desc
```

If a Microsoft Defender for Cloud assignment appears alongside your own initiative, the same controls are evaluated twice.

### When each cluster last reported

```kusto
policyresources
| where type =~ 'microsoft.policyinsights/componentpolicystates'
| extend p = properties
| summarize lastReport = max(todatetime(p.timestamp)), components = count()
    by cluster = tostring(split(tostring(p.resourceId), '/')[8])
| extend minutesSinceLastReport = datetime_diff('minute', now(), lastReport)
| order by minutesSinceLastReport desc
```

Clusters that haven't reported for over an hour may have an unhealthy add-on. Check the `azure-policy` pod in `kube-system` and the Gatekeeper pods in `gatekeeper-system`.

### Kubernetes-related assignments only

```kusto
policyresources
| where type =~ 'microsoft.policyinsights/policystates'
| where tostring(properties.resourceType) =~ 'Microsoft.ContainerService/managedClusters'
| summarize by assignmentId = tolower(tostring(properties.policyAssignmentId))
| join kind=inner (
    policyresources
    | where type =~ 'microsoft.authorization/policyassignments'
    | project assignmentId = tolower(id), displayName = tostring(properties.displayName),
              enforcementMode = tostring(properties.enforcementMode), parameters = properties.parameters
  ) on assignmentId
| project-away assignmentId1
```

### kubectl: violations for one constraint, in full

```bash
kubectl get k8sazurev2noprivilege -o json | jq -r '.items[] | .metadata.name, (.status.violations[]? | "  \(.namespace)/\(.name): \(.message)")'
```

```powershell
(kubectl get k8sazurev2noprivilege -o json | ConvertFrom-Json).items |
    ForEach-Object { $_.metadata.name; $_.status.violations | ForEach-Object { "  $($_.namespace)/$($_.name): $($_.message)" } }
```

Replace `k8sazurev2noprivilege` with any `KIND` from the script's totals output, in lower case.

---

## Custom policy: deny allow-all NetworkPolicies

`custom-policies/netpol-no-allow-all/`. NetworkPolicies are additive, so one policy that allows every peer defeats a default-deny model. This policy flags such rules. Assign it with `effect: Audit` first and review the results before switching to Deny.

### What it flags

| Flagged | Allowed |
|---|---|
| `ingress: [{}]` or `egress: [{}]` (a rule with no `from` or `to`) | Default-deny policies (no rules) |
| An empty `from` or `to` list | Peers scoped with `namespaceSelector` and `podSelector` labels |
| `namespaceSelector: {}` without a `podSelector` (every pod in every namespace) | Scoped CIDRs, such as `10.20.0.0/16` |
| `ipBlock` of `0.0.0.0/0` or `::/0` | Open egress restricted to listed ports (default: DNS on port 53) |

### Files

| File | Purpose |
|---|---|
| `template.yaml` | Gatekeeper ConstraintTemplate with the Rego rules |
| `constraint.yaml` | Example constraint, used by the tests |
| `azurepolicy.json` | Azure Policy custom definition (`Microsoft.Kubernetes.Data` mode) with the template embedded as Base64 |
| `suite.yaml`, `tests/` | gator test suite: 7 cases covering flagged and allowed patterns |

If you change `template.yaml`, re-run the tests and update the embedded copy in `azurepolicy.json`:

```bash
jq --arg c "$(base64 < template.yaml | tr -d '\n')" \
  '.properties.policyRule.then.details.templateInfo.content = $c' azurepolicy.json > azurepolicy.tmp && mv azurepolicy.tmp azurepolicy.json
```

```powershell
$def = Get-Content ./azurepolicy.json -Raw | ConvertFrom-Json -Depth 50
$def.properties.policyRule.then.details.templateInfo.content = [Convert]::ToBase64String([IO.File]::ReadAllBytes("$PWD/template.yaml"))
$def | ConvertTo-Json -Depth 50 | Set-Content ./azurepolicy.json
```

When creating the definition from PowerShell, submit `azurepolicy.json` unchanged with `Invoke-AzRestMethod` (see [PowerShell step 8.3](how-to-run-powershell.md#step-8--test-the-custom-networkpolicy-policy-optional)). `New-AzPolicyDefinition` drops the empty-object default of `labelSelector`, and assignments then fail with *missing the parameter(s) 'labelSelector'*.

### Custom policy parameters

| Parameter | Default | Meaning |
|---|---|---|
| `effect` | `Audit` | `Audit`, `Deny` or `Disabled` |
| `excludedNamespaces` | `kube-system`, `gatekeeper-system`, `azure-arc`, `azure-extensions-usage-system` | Namespaces not evaluated. Setting it replaces the default list. |
| `namespaces` | `[]` (all) | Only evaluate these namespaces |
| `labelSelector` | `{}` | Only evaluate NetworkPolicies matching this selector |
| `warn` | `false` | Return violations as kubectl warnings |
| `allowPortScopedOpenEgress` | `true` | Allow an open egress rule if it is restricted to the ports below |
| `allowedOpenEgressPorts` | `[53]` | Ports allowed for open egress |

If you use Cilium policy kinds (`CiliumNetworkPolicy`, `CiliumClusterwideNetworkPolicy`), they need a variant of this policy. This one only evaluates `networking.k8s.io/NetworkPolicy`.

---

## Limitations and caveats

- **500-record cap:** Azure Policy stores up to 500 non-compliant records per policy per cluster. The reporting can undercount on large clusters; `04-constraint-violations.sh` gives complete counts.
- **Latest state only:** Resource Graph holds current compliance only. For trends, schedule the CSV export and keep the outputs, or load them into Log Analytics.
- **Latency:** allow about 20 minutes after a workload or assignment change: the add-on syncs assignments and audits every 15 minutes, then Azure Policy publishes results.
- **Workload inference:** based on pod naming conventions. Pods created directly, or with custom naming, show as kind `Pod` under their own name.
- **Duplicate evaluation:** a control assigned more than once is reported once per assignment.
- **Unresolved effect:** for initiatives assigned at management-group scope, cluster-level results for Kubernetes policies can take longer to publish than component results. Until then the effect shows `unresolved`.
- **Scope:** results are limited to subscriptions the viewer can read.

---

## Validation

In September 2026 the toolkit was tested end to end on an AKS 1.35 cluster (Azure CNI Overlay with Cilium, Azure Policy add-on 1.17 with Gatekeeper 3.23). The cluster ran deliberately non-compliant Deployment, StatefulSet, DaemonSet, CronJob, Pod and NetworkPolicy objects. All queries, the workbook, the CSV export and the kubectl script returned the expected workloads, kinds and namespaces. The custom definition was created in Azure, installed by the add-on, and flagged the test allow-all NetworkPolicies.

---

## Further reading

- [Azure Policy for Kubernetes](https://learn.microsoft.com/azure/governance/policy/concepts/policy-for-kubernetes)
- [Built-in policy definitions for AKS](https://learn.microsoft.com/azure/aks/policy-reference)
- [Get compliance data with Azure Policy](https://learn.microsoft.com/azure/governance/policy/how-to/get-compliance-data)
- [Azure Resource Graph Explorer quickstart](https://learn.microsoft.com/azure/governance/resource-graph/first-query-portal)
- [Azure Monitor workbooks](https://learn.microsoft.com/azure/azure-monitor/visualize/workbooks-overview)
- [Gatekeeper gator CLI](https://open-policy-agent.github.io/gatekeeper/website/docs/gator/)
- [Search-AzGraph (Az.ResourceGraph)](https://learn.microsoft.com/powershell/module/az.resourcegraph/search-azgraph)
- [AKS Command Invoke](https://learn.microsoft.com/azure/aks/access-private-cluster)
