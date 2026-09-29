#Requires -Version 7.0
<#
.SYNOPSIS
    Complete Gatekeeper violation counts from one AKS cluster, per constraint and namespace.

.DESCRIPTION
    PowerShell equivalent of 04-constraint-violations.sh. Reads the Gatekeeper constraints installed by the
    Azure Policy add-on, either from the cluster in the current kubectl context or from a saved JSON export
    (for example from az aks command invoke / Invoke-AzAksRunCommand for private clusters).

    status.totalViolations is the full count; status.violations is a capped sample.
    enforcementAction: dryrun = Audit, deny = Deny, warn = Warn.

.PARAMETER InputFile
    Optional saved JSON export of the constraints (output of: kubectl get <constraint kinds> -o json).

.EXAMPLE
    ./queries/04-constraint-violations.ps1 | Tee-Object -FilePath ./results/aks-prod-01-constraints.txt

.EXAMPLE
    ./queries/04-constraint-violations.ps1 -InputFile ./results/aks-prod-01-constraints.json
#>
[CmdletBinding()]
param(
    [string] $InputFile
)

$ErrorActionPreference = 'Stop'

if ($InputFile) {
    $json = Get-Content -Path $InputFile -Raw
} else {
    if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
        throw 'kubectl not found. Install it (az aks install-cli, Install-AzAksCliTool or winget install Kubernetes.kubectl), or use -InputFile.'
    }
    $kinds = (kubectl api-resources --categories=constraint -o name) -join ','
    if ($LASTEXITCODE -ne 0) { throw "kubectl couldn't reach the cluster (exit code $LASTEXITCODE). Check the current context with 'kubectl config current-context', or use -InputFile." }
    if (-not $kinds) { throw 'No Gatekeeper constraint kinds found (is the Azure Policy add-on enabled?)' }
    $json = (kubectl get $kinds -o json) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "kubectl get failed (exit code $LASTEXITCODE)." }
}

$items = @(($json | ConvertFrom-Json -Depth 50).items)

function Get-Annotation($item, $name) {
    $annotations = $item.metadata.annotations
    if ($annotations -and $annotations.PSObject.Properties.Name -contains $name) { $annotations.$name } else { '' }
}

"== Totals per constraint"
$items | ForEach-Object {
    [pscustomobject]@{
        KIND         = $_.kind
        ACTION       = if ($_.spec.enforcementAction) { $_.spec.enforcementAction } else { 'deny' }
        VIOLATIONS   = [int]($_.status.totalViolations ?? 0)
        ASSIGNMENT   = ((Get-Annotation $_ 'azure-policy-assignment-id') -split '/')[-1]
        REFERENCE_ID = Get-Annotation $_ 'azure-policy-definition-reference-id'
    }
} | Sort-Object VIOLATIONS -Descending | Format-Table -AutoSize | Out-String -Width 400

$violations = foreach ($item in $items) {
    foreach ($v in @($item.status.violations)) {
        if ($v) {
            [pscustomobject]@{
                Namespace  = if ($v.namespace) { $v.namespace } else { '(cluster)' }
                Constraint = $item.kind
                Object     = "$($v.kind)/$($v.name)"
                Message    = $v.message
            }
        }
    }
}

"== Sampled violations by namespace and constraint kind"
$violations | Group-Object Namespace, Constraint | Sort-Object Count -Descending |
    Select-Object Count, @{ n = 'Namespace'; e = { $_.Group[0].Namespace } }, @{ n = 'Constraint'; e = { $_.Group[0].Constraint } } |
    Format-Table -AutoSize | Out-String -Width 400

"== Sampled violations (namespace/kind/name: message)"
$violations | Sort-Object Namespace, Object |
    ForEach-Object { "$($_.Namespace)/$($_.Object)`t$($_.Constraint)`t$($_.Message)" }
