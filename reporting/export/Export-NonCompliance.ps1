#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.ResourceGraph
<#
.SYNOPSIS
    Exports every non-compliant AKS workload component to CSV: one file for the estate plus one per namespace.

.DESCRIPTION
    PowerShell equivalent of export-noncompliance.sh. Runs reporting/queries/05-noncompliance-detail.kql
    through Invoke-GraphQuery.ps1 (paging through all results) and writes:
        <OutputPath>/all.csv
        <OutputPath>/by-namespace/<namespace>.csv

.PARAMETER OutputPath
    Output folder. Default: ./aks-noncompliance-<yyyyMMdd>

.PARAMETER ManagementGroup
    Management group ID(s) to query. If omitted, the subscriptions in the current Az context are used.

.PARAMETER Subscription
    Subscription ID(s) to query.

.PARAMETER IncludeSystemNamespaces
    Include kube-system, gatekeeper-system, azure-arc, azure-extensions-usage-system and flux-system.

.EXAMPLE
    ./reporting/export/Export-NonCompliance.ps1 -OutputPath ./results/noncompliance -ManagementGroup contoso-mg
#>
[CmdletBinding()]
param(
    [string] $OutputPath = "./aks-noncompliance-$(Get-Date -Format yyyyMMdd)",

    [string[]] $ManagementGroup,

    [string[]] $Subscription,

    [switch] $IncludeSystemNamespaces
)

$ErrorActionPreference = 'Stop'

$root = Resolve-Path (Join-Path $PSScriptRoot '../..')
$runner = Join-Path $root 'queries/Invoke-GraphQuery.ps1'
$source = Join-Path $root 'reporting/queries/05-noncompliance-detail.kql'

$lines = Get-Content -Path $source
if ($IncludeSystemNamespaces) {
    $lines = $lines | Where-Object { $_ -notmatch '^\|\s*where namespace !in~' }
}
$tempQuery = New-TemporaryFile
Set-Content -Path $tempQuery -Value $lines

$columns = 'cluster', 'namespace', 'workloadKind', 'workload', 'objectKind', 'component', 'policy',
           'effect', 'assignment', 'initiative', 'lastEvaluated', 'subscriptionId'

try {
    $scope = @{}
    if ($ManagementGroup) { $scope.ManagementGroup = $ManagementGroup }
    elseif ($Subscription) { $scope.Subscription = $Subscription }

    $rows = @(& $runner -QueryFile $tempQuery @scope | Select-Object -Property $columns)
}
finally {
    Remove-Item -Path $tempQuery -ErrorAction SilentlyContinue
}

$byNamespace = Join-Path $OutputPath 'by-namespace'
New-Item -ItemType Directory -Force -Path $byNamespace | Out-Null

$all = Join-Path $OutputPath 'all.csv'
if ($rows.Count -eq 0) {
    Set-Content -Path $all -Value ($columns -join ',')
} else {
    $rows | Export-Csv -Path $all -NoTypeInformation -Encoding utf8
}

$groups = $rows | Group-Object -Property namespace
foreach ($group in $groups) {
    $safeName = $group.Name -replace '[^A-Za-z0-9._-]', '_'
    $group.Group | Export-Csv -Path (Join-Path $byNamespace "$safeName.csv") -NoTypeInformation -Encoding utf8
}

Write-Information -InformationAction Continue "Rows: $($rows.Count)  namespaces: $(@($groups).Count)  output: $OutputPath"
