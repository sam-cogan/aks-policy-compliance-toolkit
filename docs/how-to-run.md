# How to run the toolkit

Step-by-step instructions for running each part of the toolkit. For what each file does, how the reporting works and more example queries, see the [reference guide](reference.md).

Everything in this toolkit is **read-only** against your environment, except two optional steps that are clearly marked: deploying the workbook (step 7) and creating the custom policy definition (step 8.3).

## Contents

- [Before you start](#before-you-start)
- [Step 1 — Get the toolkit](#step-1--get-the-toolkit)
- [Step 2 — Sign in and choose the scope](#step-2--sign-in-and-choose-the-scope)
- [Step 3 — Inventory policy assignments](#step-3--inventory-policy-assignments)
- [Step 4 — Check cluster-level compliance](#step-4--check-cluster-level-compliance)
- [Step 5 — Export non-compliant workloads to CSV](#step-5--export-non-compliant-workloads-to-csv)
- [Step 6 — Get complete in-cluster counts](#step-6--get-complete-in-cluster-counts)
- [Step 7 — Deploy the workbook (optional)](#step-7--deploy-the-workbook-optional)
- [Step 8 — Test the custom NetworkPolicy policy (optional)](#step-8--test-the-custom-networkpolicy-policy-optional)
- [Troubleshooting](#troubleshooting)
- [Clean up](#clean-up)

---

## Before you start

### Time needed

| Steps | Time |
|---|---|
| 1–5: inventory, compliance and CSV export | 15–20 minutes |
| 6: in-cluster counts | About 5 minutes per cluster |
| 7: workbook | About 10 minutes |
| 8: custom policy test | About 10 minutes |

### Access needed

| Access | Needed for | Steps |
|---|---|---|
| **Reader** on every subscription containing AKS clusters, or on a management group above them | Resource Graph queries, CSV export, workbook | 2–5, 7 |
| **Azure Kubernetes Service Cluster User** role, plus Kubernetes RBAC to `get` and `list` Gatekeeper constraints (`constraints.gatekeeper.sh`). `cluster-admin` has this; read-only roles may not. | In-cluster counts | 6 |
| **Workbook Contributor** (or Contributor) on one resource group | Deploying the workbook | 7 |
| **Resource Policy Contributor** at the target scope | Creating the custom policy definition, only when agreed | 8.3 |

Resource Graph only returns results for subscriptions you can read. If clusters are missing from the results, check your access first.

### Where to run it

**Option A — Azure Cloud Shell (recommended).** No installation needed. Open [shell.azure.com](https://shell.azure.com), or select the Cloud Shell icon in the Azure portal, and choose **Bash**. Cloud Shell includes `az`, `jq`, `git` and `kubectl`, and is already signed in.

**Option B — Your own machine** (macOS, Linux, or WSL on Windows). Install:

| Tool | Install | Check |
|---|---|---|
| Azure CLI | [Install the Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) | `az version` |
| Resource Graph extension | `az extension add -n resource-graph` | `az graph query -q "resources \| take 1" -o table` |
| jq | macOS: `brew install jq` · Ubuntu/WSL: `sudo apt-get install -y jq` | `jq --version` |
| kubectl and kubelogin (step 6) | `az aks install-cli` | `kubectl version --client` · `kubelogin --version` |
| git | macOS: `xcode-select --install` · Ubuntu/WSL: `sudo apt-get install -y git` | `git --version` |
| gator (step 8 only) | See [step 8](#step-8--test-the-custom-networkpolicy-policy-optional) | `gator --version` |

The shell scripts are bash. They don't run in PowerShell or the Windows command prompt; use WSL or Cloud Shell.

### A helper for saving results

Steps 3 and 4 save query results as CSV. To avoid repeating the conversion, define this once in your shell session:

```bash
tocsv() { jq -r 'if (.data|length)==0 then "no rows returned" else ((.data[0]|keys_unsorted|@csv),(.data[]|[.[]|tostring]|@csv)) end'; }
```

---

## Step 1 — Get the toolkit

```bash
git clone https://github.com/sam-cogan/aks-policy-compliance-toolkit.git
cd aks-policy-compliance-toolkit
chmod +x queries/04-constraint-violations.sh reporting/export/export-noncompliance.sh
mkdir -p results
ls
```

You should see `README.md`, `docs/`, `queries/`, `reporting/`, `custom-policies/` and the new, empty `results/` folder.

No git? On the GitHub page select **Code → Download ZIP**, extract it, and `cd` into the extracted folder.

## Step 2 — Sign in and choose the scope

1. **Sign in** (skip in Cloud Shell):

   ```bash
   az login
   ```

   If your account has access to several tenants, add `--tenant <tenant-id>`.

2. **Choose the scope.** Querying a **management group** is simplest when your AKS subscriptions sit under one. List the management groups you can see and note the `Name` value, which is the management group ID:

   ```bash
   az account management-group list --query "[].{Name:name, DisplayName:displayName}" -o table
   ```

   If you query **subscriptions** instead, leave out the `--management-groups` options in later steps. The CLI then uses every subscription in your current context:

   ```bash
   az account list --query "[?state=='Enabled'].{Name:name, Id:id}" -o table
   ```

   To make the later commands copy-and-paste ready, set a variable:

   ```bash
   MG=<management-group-id>                  # management group scope
   SCOPE=(--management-groups "$MG")
   # or, for subscription scope:
   # SCOPE=()
   ```

3. **Confirm Resource Graph can see your clusters**, and check whether the Azure Policy add-on is enabled on each one:

   ```bash
   az graph query "${SCOPE[@]}" --first 1000 -o table -q "resources
   | where type =~ 'microsoft.containerservice/managedclusters'
   | project cluster = name, resourceGroup, subscriptionId,
             policyAddon = coalesce(tobool(properties.addonProfiles.azurepolicy.enabled), false)"
   ```

   Every cluster you expect should be listed. Clusters with `policyAddon` = `False` don't report Kubernetes policy compliance.

## Step 3 — Inventory policy assignments

This lists which policies and initiatives are assigned, their enforcement mode, effect parameters and overrides.

**With the CLI:**

```bash
az graph query "${SCOPE[@]}" --first 1000 -o json \
  -q "$(grep -v '^//' queries/01-aks-assignments.kql)" | tocsv > results/01-assignments.csv
wc -l results/01-assignments.csv
```

The `grep -v '^//'` strips the comment lines, which the CLI doesn't accept.

**Or in the portal:**

1. In the Azure portal, search for **Resource Graph Explorer** and open it.
2. Use the scope selector at the top of the editor to choose your management group or subscriptions.
3. Open `queries/01-aks-assignments.kql` in a text editor, copy the whole file and paste it into the query editor. The comment lines are fine here.
4. Select **Run query**.
5. Select **Download as CSV** and save the file as `01-assignments.csv`.

**What to look for:** your guardrail initiatives, whether `enforcementMode` is `Default` or `DoNotEnforce`, the `effect` value under `parameters`, and any `overrides`. Assignments made by Microsoft Defender for Cloud (for example the *Microsoft cloud security benchmark*) also appear.

## Step 4 — Check cluster-level compliance

These show which policies each cluster fails, and how many Kubernetes objects fail each policy.

```bash
for q in 02-aks-compliance-by-policy 03-aks-noncompliant-components; do
  az graph query "${SCOPE[@]}" --first 1000 -o json \
    -q "$(grep -v '^//' queries/$q.kql)" | tocsv > results/$q.csv
  echo "$q: $(($(wc -l < results/$q.csv) - 1)) rows"
done
```

Or run each file in Resource Graph Explorer as in step 3.

If a result shows `no rows returned`, see [Troubleshooting](#troubleshooting).

## Step 5 — Export non-compliant workloads to CSV

`export-noncompliance.sh` lists every non-compliant pod, NetworkPolicy and other Kubernetes object, per policy, across all clusters in scope. It pages through the results, so it isn't limited to 1,000 rows.

1. **Run it:**

   ```bash
   # Management group scope:
   ./reporting/export/export-noncompliance.sh ./results/noncompliance "$MG"

   # Or subscription scope:
   ./reporting/export/export-noncompliance.sh ./results/noncompliance
   ```

   When it finishes, it prints a summary:

   ```text
   Rows: 1234  namespaces: 18  output: ./results/noncompliance
   ```

2. **Check the output:**

   ```bash
   ls results/noncompliance results/noncompliance/by-namespace
   head -5 results/noncompliance/all.csv
   ```

   - `all.csv`: every finding across the estate.
   - `by-namespace/<namespace>.csv`: one file per namespace, for sending to the owning team.

   Columns: `cluster, namespace, workloadKind, workload, objectKind, component, policy, effect, assignment, initiative, lastEvaluated, subscriptionId`. The [reference guide](reference.md#csv-export) describes each column.

3. **Optional — include system namespaces.** The export excludes `kube-system`, `gatekeeper-system`, `azure-arc`, `azure-extensions-usage-system` and `flux-system`. To include them, delete the line starting `| where namespace !in~` in the script and run it again.

To open a CSV in Excel, use **Data → From Text/CSV** so values are imported as text.

## Step 6 — Get complete in-cluster counts

Azure Policy stores up to 500 non-compliant records per policy per cluster, so large clusters can be under-reported in steps 4 and 5. This script reads the Gatekeeper constraints directly from a cluster and gives the complete count. Run it against at least one non-production and one production cluster.

### 6a — Clusters you can reach with kubectl

1. **Get credentials:**

   ```bash
   az account set --subscription <subscription-id>
   az aks get-credentials --resource-group <resource-group> --name <cluster-name> --overwrite-existing
   ```

2. **Microsoft Entra ID integrated clusters:** convert the kubeconfig to use your Azure CLI sign-in, so kubectl doesn't prompt for a device code:

   ```bash
   kubelogin convert-kubeconfig -l azurecli
   ```

3. **Check access.** You should see `gatekeeper-audit` and `gatekeeper-controller` pods:

   ```bash
   kubectl get pods -n gatekeeper-system
   ```

4. **Run the script** and save the output:

   ```bash
   ./queries/04-constraint-violations.sh | tee results/<cluster-name>-constraints.txt
   ```

### 6b — Private clusters you can't reach directly

Use [AKS Command Invoke](https://learn.microsoft.com/azure/aks/access-private-cluster) to export the constraints as JSON, then run the script locally against the file:

```bash
az aks command invoke --resource-group <resource-group> --name <cluster-name> \
  --command 'kubectl get $(kubectl api-resources --categories=constraint -o name | paste -sd, -) -o json' \
  --query logs -o tsv > results/<cluster-name>-constraints.json

./queries/04-constraint-violations.sh results/<cluster-name>-constraints.json | tee results/<cluster-name>-constraints.txt
```

Command Invoke must be enabled on the cluster, and your identity needs access to run it.

### Read the output

- **Totals per constraint:** one row per Gatekeeper constraint. `ACTION` is `dryrun` for Audit and `deny` for Deny. `VIOLATIONS` is the complete count. `ASSIGNMENT` and `REFERENCE_ID` identify the Azure Policy assignment and the policy within an initiative.
- **Sampled violations by namespace and constraint kind:** where the violations are concentrated.
- **Sampled violations:** each object and the reason it failed. Gatekeeper caps this list, so it's a sample; use `VIOLATIONS` for totals.

Repeat for each cluster.

## Step 7 — Deploy the workbook (optional)

> **Creates a resource:** one Azure Monitor workbook (`Microsoft.Insights/workbooks`) in the resource group you choose. Nothing else is created or changed.

The workbook gives a consolidated, filterable view of non-compliant workloads across all clusters. Once deployed, anyone who can read the AKS subscriptions can use it.

### Option A — Deploy with Bicep

```bash
az group create --name <resource-group> --location <region>   # only if the group doesn't exist
az deployment group create \
  --resource-group <resource-group> \
  --template-file reporting/workbook/main.bicep \
  --query properties.outputs.workbookResourceId.value -o tsv
```

Optional parameters: `--parameters displayName="AKS policy non-compliance" location=<region>`.

### Option B — Import in the portal

1. In the Azure portal, open **Monitor → Workbooks** and select **+ New**.
2. Select the **Advanced Editor** button (`</>`) in the toolbar.
3. On the **Gallery Template** tab, delete the existing content and paste the entire content of `reporting/workbook/aks-policy-noncompliance.workbook.json`.
4. Select **Apply**, then **Done Editing**.
5. Select **Save** (disk icon), enter a title, choose the subscription, resource group and location, and select **Apply**.

### Use the workbook

1. Open **Monitor → Workbooks** and select **AKS policy non-compliance**, or open it from its resource group.
2. In **Subscriptions**, confirm the subscriptions with AKS clusters are selected. The default is all subscriptions you can see.
3. Use the tabs:

   | Tab | Use it to |
   |---|---|
   | **Overview** | See totals, top namespaces and policies, and a cluster × policy heat map |
   | **By namespace** | Select a namespace row to list its workloads underneath |
   | **By workload** | See each workload and every policy it violates |
   | **By policy** | Select a policy row to list the affected workloads |
   | **All findings** | Search every finding |
   | **Cluster level** | See non-compliant AKS cluster resources, including cluster-configuration policies |

4. Narrow the results with the **Clusters**, **Namespaces**, **Policies** and **Effect** filters. Set **Hide system namespaces** to **No** to include them.
5. Export any grid with its download icon, or with the `…` menu → **Export to Excel**.

Results appear about 20 minutes after a workload is deployed or changed.

## Step 8 — Test the custom NetworkPolicy policy (optional)

The custom policy flags NetworkPolicy rules that allow traffic from or to any peer. Steps 8.1 and 8.2 run locally and need no Azure access.

1. **Install gator**, the Gatekeeper CLI, from the [Gatekeeper releases](https://github.com/open-policy-agent/gatekeeper/releases) page. On Linux or Cloud Shell:

   ```bash
   V=v3.23.1
   curl -sL -o /tmp/gator.tgz "https://github.com/open-policy-agent/gatekeeper/releases/download/$V/gator-$V-linux-amd64.tar.gz"
   mkdir -p ~/bin && tar -xzf /tmp/gator.tgz -C ~/bin gator && export PATH="$HOME/bin:$PATH"
   gator --version
   ```

   On macOS, replace `linux-amd64` with `darwin-arm64` (Apple silicon) or `darwin-amd64` (Intel).

2. **Run the tests:**

   ```bash
   (cd custom-policies/netpol-no-allow-all && gator verify . -v)
   ```

   All seven cases should show `PASS`.

3. **Optional, when agreed — create the definition and assign it in Audit mode.**

   > **Changes Azure Policy:** creates a custom policy definition and an Audit assignment. Audit reports violations and doesn't block anything.

   ```bash
   cd custom-policies/netpol-no-allow-all
   jq '.properties.policyRule' azurepolicy.json > /tmp/rule.json
   jq '.properties.parameters' azurepolicy.json > /tmp/params.json

   az policy definition create --name netpol-no-allow-all \
     --display-name "$(jq -r '.properties.displayName' azurepolicy.json)" \
     --mode Microsoft.Kubernetes.Data --rules /tmp/rule.json --params /tmp/params.json \
     --metadata category=Kubernetes --management-group "$MG"

   az policy assignment create --name netpol-no-allow-all-audit \
     --display-name "NetworkPolicies should not allow any peer (Audit)" \
     --policy "/providers/Microsoft.Management/managementGroups/$MG/providers/Microsoft.Authorization/policyDefinitions/netpol-no-allow-all" \
     --scope <scope-id> \
     --params '{"effect":{"value":"Audit"}}'
   cd -
   ```

   `<scope-id>` is where to assign it: a management group (`/providers/Microsoft.Management/managementGroups/<id>`), subscription (`/subscriptions/<id>`) or resource group. To create the definition in a subscription instead, replace `--management-group "$MG"` with `--subscription <subscription-id>` and adjust the `--policy` ID to `/subscriptions/<subscription-id>/providers/Microsoft.Authorization/policyDefinitions/netpol-no-allow-all`.

   About 15 minutes after assignment, the add-on installs the constraint on each cluster in scope. Violations then appear in the workbook and exports under the policy's display name. Parameters are described in the [reference guide](reference.md#custom-policy-parameters).

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `az graph query`: command not found or unrecognised | Install the extension: `az extension add -n resource-graph` |
| `az graph query` returns `AccessDenied` | The subscription is in another tenant, or you lack Reader. Run `az login --tenant <tenant-id>`, or `az account set --subscription <id>` for a subscription in the right tenant. |
| Queries return `no rows returned` | Check the scope (step 2.3) and that the Azure Policy add-on is enabled. Allow about 20 minutes after assigning a policy or deploying a workload. Component results only exist for Kubernetes (`Microsoft.Kubernetes.Data`) policies. |
| Some clusters are missing | You don't have Reader on their subscription, or they are outside the management group you chose. |
| The `effect` column shows `unresolved` | The policy's cluster-level result hasn't published yet, typically for initiatives assigned at management-group scope. Check the assignment's effect in `01-assignments.csv`. |
| The same pod appears twice for one control | Two assignments evaluate it, for example your initiative and Defender for Cloud's benchmark. The `assignment` column separates them. |
| `Permission denied` running a script | `chmod +x queries/04-constraint-violations.sh reporting/export/export-noncompliance.sh` |
| `jq: command not found` | Install jq (see [Before you start](#before-you-start)). |
| `No Gatekeeper constraint kinds found` | The Azure Policy add-on isn't enabled on that cluster, or no Kubernetes policies are assigned to it yet. |
| kubectl returns `Unauthorized` or asks for a device code | Run `kubelogin convert-kubeconfig -l azurecli` (step 6a.2). |
| kubectl returns `Forbidden` listing constraints | Your Kubernetes role can't read Gatekeeper constraints (`constraints.gatekeeper.sh`). Ask for read access to that API group, use an admin identity, or use step 6b. |
| kubectl can't connect | The cluster is private. Use step 6b. |
| The workbook shows `<query pending>` in the filters | Wait a few seconds after it opens. If it persists, select at least one subscription in **Subscriptions**. |
| The workbook shows `Query is invalid` | The JSON was probably truncated when pasting in step 7, option B. Deploy with Bicep (option A) instead. |
| `gator: command not found` | Run `export PATH="$HOME/bin:$PATH"`. |

## Clean up

- **Workbook:** open it, then select `…` → **Delete**, or delete the `Microsoft.Insights/workbooks` resource from its resource group.
- **Custom policy:** `az policy assignment delete --name netpol-no-allow-all-audit --scope <scope-id>`, then `az policy definition delete --name netpol-no-allow-all --management-group "$MG"`.
- **Local results:** the `results/` folder contains cluster, namespace and workload names. Delete it when it's no longer needed.
