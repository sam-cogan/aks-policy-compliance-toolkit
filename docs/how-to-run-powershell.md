# How to run the toolkit — PowerShell

Step-by-step instructions for running the toolkit from **PowerShell 7** on Windows, macOS or Linux, or from **Azure Cloud Shell (PowerShell)**. It uses the Az PowerShell modules, not the Azure CLI or bash. For bash, see [How to run the toolkit (bash)](how-to-run.md). For what each file does and example queries, see the [reference guide](reference.md).

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

### Where to run it

**Option A — Azure Cloud Shell (recommended).** Open [shell.azure.com](https://shell.azure.com), or select the Cloud Shell icon in the Azure portal, and choose **PowerShell**. It includes PowerShell 7, the Az modules, `git` and `kubectl`, and is already signed in.

**Option B — Your own machine.** Install:

| Tool | Install (Windows) | Check |
|---|---|---|
| PowerShell 7.2 or later | `winget install --id Microsoft.PowerShell --source winget` | `$PSVersionTable.PSVersion` |
| Az PowerShell modules | `Install-Module Az.Accounts, Az.ResourceGraph, Az.Resources, Az.Aks -Scope CurrentUser` | `Get-Module -ListAvailable Az.ResourceGraph` |
| kubectl and kubelogin (step 6) | `Install-AzAksCliTool` (from Az.Aks), or `winget install Kubernetes.kubectl` and `winget install Microsoft.Azure.Kubelogin` | `kubectl version --client` · `kubelogin --version` |
| git | `winget install --id Git.Git` | `git --version` |
| gator (step 8 only) | Not published for Windows; see [step 8](#step-8--test-the-custom-networkpolicy-policy-optional) | `gator --version` |

Run everything in **PowerShell 7** (`pwsh`), not Windows PowerShell 5.1. The scripts require version 7.

On macOS or Linux, install PowerShell from [Install PowerShell](https://learn.microsoft.com/powershell/scripting/install/installing-powershell), then install the same modules.

### Script execution policy (Windows)

If PowerShell refuses to run the scripts with *"running scripts is disabled on this system"* or *"is not digitally signed"*, allow them for the current session only:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

If you downloaded the toolkit as a zip, also unblock the files once:

```powershell
Get-ChildItem -Recurse | Unblock-File
```

---

## Step 1 — Get the toolkit

```powershell
git clone https://github.com/sam-cogan/aks-policy-compliance-toolkit.git
Set-Location aks-policy-compliance-toolkit
New-Item -ItemType Directory -Force -Path ./results | Out-Null
Get-ChildItem
```

You should see `README.md`, `docs`, `queries`, `reporting`, `custom-policies` and the new, empty `results` folder.

No git? On the GitHub page select **Code → Download ZIP**, extract it, `Set-Location` into the extracted folder, and run `Get-ChildItem -Recurse | Unblock-File`.

## Step 2 — Sign in and choose the scope

1. **Sign in** (skip in Cloud Shell):

   ```powershell
   Connect-AzAccount
   # Several tenants?  Connect-AzAccount -Tenant <tenant-id>
   # No browser?       Connect-AzAccount -UseDeviceAuthentication
   ```

2. **Choose the scope.** Querying a **management group** is simplest when your AKS subscriptions sit under one. List the management groups you can see and note the `Name` value, which is the management group ID:

   ```powershell
   Get-AzManagementGroup | Select-Object Name, DisplayName
   ```

   Set the scope once, so later commands can be copied as-is:

   ```powershell
   $MG = '<management-group-id>'
   $Scope = @{ ManagementGroup = $MG }       # management group scope
   # $Scope = @{}                            # or: every subscription in your current Az context
   # $Scope = @{ Subscription = '<sub-id-1>', '<sub-id-2>' }   # or: specific subscriptions
   ```

   To list the subscriptions in your context: `Get-AzSubscription | Select-Object Name, Id, State`.

3. **Confirm Resource Graph can see your clusters**, and check whether the Azure Policy add-on is enabled on each one:

   ```powershell
   Search-AzGraph @Scope -First 1000 -Query @'
   resources
   | where type =~ 'microsoft.containerservice/managedclusters'
   | project cluster = name, resourceGroup, subscriptionId,
             policyAddon = coalesce(tobool(properties.addonProfiles.azurepolicy.enabled), false)
   '@ | Format-Table cluster, resourceGroup, policyAddon
   ```

   Every cluster you expect should be listed. Clusters with `policyAddon` = `False` don't report Kubernetes policy compliance.

## Step 3 — Inventory policy assignments

`queries/Invoke-GraphQuery.ps1` runs any toolkit `.kql` file. It strips the comment lines, pages through all results, converts nested values to JSON text, and writes CSV.

```powershell
./queries/Invoke-GraphQuery.ps1 -QueryFile ./queries/01-aks-assignments.kql @Scope -OutFile ./results/01-assignments.csv
```

It prints the number of rows written. To look at the results on screen instead, leave out `-OutFile`:

```powershell
./queries/Invoke-GraphQuery.ps1 -QueryFile ./queries/01-aks-assignments.kql @Scope |
    Select-Object displayName, enforcementMode, scope | Format-Table -AutoSize
```

You can also run the `.kql` file in the portal's **Resource Graph Explorer** and select **Download as CSV** (see [step 3 of the bash guide](how-to-run.md#step-3--inventory-policy-assignments)).

**What to look for:** your guardrail initiatives, whether `enforcementMode` is `Default` or `DoNotEnforce`, the `effect` value in `parameters`, and any `overrides`. Assignments made by Microsoft Defender for Cloud (for example the *Microsoft cloud security benchmark*) also appear.

## Step 4 — Check cluster-level compliance

These show which policies each cluster fails, and how many Kubernetes objects fail each policy.

```powershell
foreach ($q in '02-aks-compliance-by-policy', '03-aks-noncompliant-components') {
    ./queries/Invoke-GraphQuery.ps1 -QueryFile "./queries/$q.kql" @Scope -OutFile "./results/$q.csv"
}
```

If a file contains only `no rows returned`, see [Troubleshooting](#troubleshooting).

## Step 5 — Export non-compliant workloads to CSV

`reporting/export/Export-NonCompliance.ps1` lists every non-compliant pod, NetworkPolicy and other Kubernetes object, per policy, across all clusters in scope. It pages through the results, so it isn't limited to 1,000 rows.

1. **Run it:**

   ```powershell
   ./reporting/export/Export-NonCompliance.ps1 -OutputPath ./results/noncompliance @Scope
   ```

   When it finishes, it prints a summary:

   ```text
   Rows: 1234  namespaces: 18  output: ./results/noncompliance
   ```

2. **Check the output:**

   ```powershell
   Get-ChildItem ./results/noncompliance, ./results/noncompliance/by-namespace
   Import-Csv ./results/noncompliance/all.csv | Select-Object -First 5 | Format-Table cluster, namespace, workload, policy, effect
   ```

   - `all.csv`: every finding across the estate.
   - `by-namespace\<namespace>.csv`: one file per namespace, for sending to the owning team.

   Columns: `cluster, namespace, workloadKind, workload, objectKind, component, policy, effect, assignment, initiative, lastEvaluated, subscriptionId`. The [reference guide](reference.md#csv-export) describes each column.

3. **Optional — include system namespaces** (`kube-system`, `gatekeeper-system`, `azure-arc`, `azure-extensions-usage-system`, `flux-system`), which are excluded by default:

   ```powershell
   ./reporting/export/Export-NonCompliance.ps1 -OutputPath ./results/noncompliance-all @Scope -IncludeSystemNamespaces
   ```

To open a CSV in Excel, use **Data → From Text/CSV** so values are imported as text.

## Step 6 — Get complete in-cluster counts

Azure Policy stores up to 500 non-compliant records per policy per cluster, so large clusters can be under-reported in steps 4 and 5. `queries/04-constraint-violations.ps1` reads the Gatekeeper constraints directly from a cluster and gives the complete count. Run it against at least one non-production and one production cluster.

### 6a — Clusters you can reach with kubectl

1. **Get credentials:**

   ```powershell
   Set-AzContext -Subscription '<subscription-id>'
   Import-AzAksCredential -ResourceGroupName '<resource-group>' -Name '<cluster-name>' -Force
   ```

2. **Microsoft Entra ID integrated clusters:** convert the kubeconfig so kubectl can sign in. In Cloud Shell, or if the Azure CLI is also installed and signed in, use `azurecli`; otherwise use `devicecode`:

   ```powershell
   kubelogin convert-kubeconfig -l azurecli      # or: kubelogin convert-kubeconfig -l devicecode
   ```

3. **Check access.** You should see `gatekeeper-audit` and `gatekeeper-controller` pods:

   ```powershell
   kubectl get pods -n gatekeeper-system
   ```

4. **Run the script** and save the output:

   ```powershell
   ./queries/04-constraint-violations.ps1 | Tee-Object -FilePath ./results/<cluster-name>-constraints.txt
   ```

### 6b — Private clusters you can't reach directly

Use AKS Run Command to export the constraints as JSON, then run the script locally against the file:

```powershell
$run = Invoke-AzAksRunCommand -ResourceGroupName '<resource-group>' -Name '<cluster-name>' -Force `
    -Command 'kubectl get $(kubectl api-resources --categories=constraint -o name | paste -sd, -) -o json'
$run.Logs | Set-Content -Path ./results/<cluster-name>-constraints.json

./queries/04-constraint-violations.ps1 -InputFile ./results/<cluster-name>-constraints.json |
    Tee-Object -FilePath ./results/<cluster-name>-constraints.txt
```

The command inside `-Command` runs on the cluster's Run Command pod, not in PowerShell, so keep it in single quotes exactly as shown. Run Command must be enabled on the cluster.

### Read the output

- **Totals per constraint:** one row per Gatekeeper constraint. `ACTION` is `dryrun` for Audit and `deny` for Deny. `VIOLATIONS` is the complete count. `ASSIGNMENT` and `REFERENCE_ID` identify the Azure Policy assignment and the policy within an initiative.
- **Sampled violations by namespace and constraint kind:** where the violations are concentrated.
- **Sampled violations:** each object and the reason it failed. Gatekeeper caps this list, so it's a sample; use `VIOLATIONS` for totals.

Repeat for each cluster.

## Step 7 — Deploy the workbook (optional)

> **Creates a resource:** one Azure Monitor workbook (`Microsoft.Insights/workbooks`) in the resource group you choose. Nothing else is created or changed.

### Option A — Deploy with PowerShell

`main.json` is the compiled ARM template of `main.bicep`, so no Bicep installation is needed:

```powershell
New-AzResourceGroup -Name '<resource-group>' -Location '<region>'    # only if the group doesn't exist
$deployment = New-AzResourceGroupDeployment -ResourceGroupName '<resource-group>' `
    -TemplateFile ./reporting/workbook/main.json
$deployment.Outputs.workbookResourceId.Value
```

Optional parameters: `-displayName 'AKS policy non-compliance' -location '<region>'`.

### Option B — Import in the portal

1. In the Azure portal, open **Monitor → Workbooks** and select **+ New**.
2. Select the **Advanced Editor** button (`</>`) in the toolbar.
3. On the **Gallery Template** tab, delete the existing content and paste the entire content of `reporting/workbook/aks-policy-noncompliance.workbook.json`. To copy it to the clipboard on Windows: `Get-Content ./reporting/workbook/aks-policy-noncompliance.workbook.json -Raw | Set-Clipboard`.
4. Select **Apply**, then **Done Editing**.
5. Select **Save** (disk icon), enter a title, choose the subscription, resource group and location, and select **Apply**.

### Use the workbook

See [Use the workbook](how-to-run.md#use-the-workbook) in the bash guide; it's the same in the portal.

## Step 8 — Test the custom NetworkPolicy policy (optional)

The custom policy flags NetworkPolicy rules that allow traffic from or to any peer. Steps 8.1 and 8.2 run locally and need no Azure access.

1. **Install gator**, the Gatekeeper CLI. Gatekeeper publishes gator for Linux and macOS only, so on Windows run steps 8.1 and 8.2 in one of these:

   - **Cloud Shell (PowerShell or Bash)** or **WSL:** download the Linux build:

     ```powershell
     $v = 'v3.23.1'
     $dest = Join-Path $HOME 'bin'
     New-Item -ItemType Directory -Force -Path $dest | Out-Null
     Invoke-WebRequest -Uri "https://github.com/open-policy-agent/gatekeeper/releases/download/$v/gator-$v-linux-amd64.tar.gz" -OutFile /tmp/gator.tgz
     tar -xzf /tmp/gator.tgz -C $dest gator
     $env:PATH = "$dest$([IO.Path]::PathSeparator)$env:PATH"
     gator --version
     ```

     On macOS, use `darwin-arm64` (Apple silicon) or `darwin-amd64` (Intel) in the file name.

   - **Windows with Go installed:** build it: `go install github.com/open-policy-agent/gatekeeper/v3/cmd/gator@v3.23.1`, then use `gator.exe` from `$(go env GOPATH)\bin`.

2. **Run the tests:**

   ```powershell
   Push-Location ./custom-policies/netpol-no-allow-all
   gator verify . -v
   Pop-Location
   ```

   All seven cases should show `PASS`.

3. **Optional, when agreed — create the definition and assign it in Audit mode.**

   > **Changes Azure Policy:** creates a custom policy definition and an Audit assignment. Audit reports violations and doesn't block anything.

   Create the definition from `azurepolicy.json` as-is, through the Azure Resource Manager REST API. `New-AzPolicyDefinition` drops the empty-object default of the `labelSelector` parameter, which then makes assignments fail.

   ```powershell
   $definitionScope = "/providers/Microsoft.Management/managementGroups/$MG"   # or "/subscriptions/<subscription-id>"
   $definitionId    = "$definitionScope/providers/Microsoft.Authorization/policyDefinitions/netpol-no-allow-all"

   $response = Invoke-AzRestMethod -Method PUT -Path "$($definitionId)?api-version=2023-04-01" `
       -Payload (Get-Content ./custom-policies/netpol-no-allow-all/azurepolicy.json -Raw)
   $response.StatusCode      # 200 or 201

   $definition = Get-AzPolicyDefinition -Id $definitionId
   New-AzPolicyAssignment -Name 'netpol-no-allow-all-audit' `
       -DisplayName 'NetworkPolicies should not allow any peer (Audit)' `
       -PolicyDefinition $definition -Scope '<scope-id>' `
       -PolicyParameterObject @{ effect = 'Audit' }
   ```

   `<scope-id>` is where to assign it: a management group (`/providers/Microsoft.Management/managementGroups/<id>`), subscription (`/subscriptions/<id>`) or resource group.

   About 15 minutes after assignment, the add-on installs the constraint on each cluster in scope. Violations then appear in the workbook and exports under the policy's display name. Parameters are described in the [reference guide](reference.md#custom-policy-parameters).

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| *running scripts is disabled on this system* / *is not digitally signed* | `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass`; for a downloaded zip also `Get-ChildItem -Recurse \| Unblock-File`. |
| *The script ... cannot be run because it contained a "#requires" statement for PowerShell 7.0* | You're in Windows PowerShell 5.1. Start PowerShell 7 with `pwsh`. |
| *The term 'Search-AzGraph' is not recognized* or a `#requires` modules error | `Install-Module Az.Accounts, Az.ResourceGraph -Scope CurrentUser` |
| *Not signed in to Azure. Run Connect-AzAccount first.* | Run `Connect-AzAccount`. |
| `Search-AzGraph` returns `AuthorizationFailed` or no rows for some subscriptions | You lack Reader there, or they're in another tenant: `Connect-AzAccount -Tenant <tenant-id>`. |
| Files contain `no rows returned` | Check the scope (step 2.3) and that the Azure Policy add-on is enabled. Allow about 20 minutes after assigning a policy or deploying a workload. Component results only exist for Kubernetes (`Microsoft.Kubernetes.Data`) policies. |
| The `effect` column shows `unresolved` | The policy's cluster-level result hasn't published yet, typically for initiatives assigned at management-group scope. Check the assignment's effect in `01-assignments.csv`. |
| The same pod appears twice for one control | Two assignments evaluate it, for example your initiative and Defender for Cloud's benchmark. The `assignment` column separates them. |
| *kubectl couldn't reach the cluster* | Check `kubectl config current-context`, re-run step 6a.1, or use step 6b. |
| *No Gatekeeper constraint kinds found* | The Azure Policy add-on isn't enabled on that cluster, or no Kubernetes policies are assigned to it yet. |
| kubectl returns `Unauthorized` or opens a browser or device code every time | Run `kubelogin convert-kubeconfig` (step 6a.2). |
| kubectl returns `Forbidden` listing constraints | Your Kubernetes role can't read Gatekeeper constraints (`constraints.gatekeeper.sh`). Ask for read access to that API group, use an admin identity, or use step 6b. |
| `New-AzResourceGroupDeployment` asks for a Bicep installation | Use `main.json`, not `main.bicep`. |
| The workbook shows `Query is invalid` after importing | The JSON was truncated when pasting. Use `Set-Clipboard` as in step 7, option B, or deploy with option A. |
| Assigning the custom policy fails with *missing the parameter(s) 'labelSelector'* | The definition was created with `New-AzPolicyDefinition`. Recreate it with `Invoke-AzRestMethod` as in step 8.3. |
| `gator` is not recognised | Add the folder you extracted it to to `PATH` (step 8.1). There is no Windows release; use Cloud Shell, WSL or a Go build. |

## Clean up

- **Workbook:** open it, then select `…` → **Delete**, or `Remove-AzResource -ResourceId <workbookResourceId> -Force`.
- **Custom policy:**

  ```powershell
  Remove-AzPolicyAssignment -Name 'netpol-no-allow-all-audit' -Scope '<scope-id>'
  Remove-AzPolicyDefinition -Id $definitionId -Force
  ```

- **Local results:** the `results` folder contains cluster, namespace and workload names. Delete it when it's no longer needed.
