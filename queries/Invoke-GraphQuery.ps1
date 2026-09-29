#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.ResourceGraph
<#
.SYNOPSIS
    Runs a toolkit Resource Graph query (.kql file) and returns or saves every row.

.DESCRIPTION
    Removes the // comment lines from the .kql file, runs it with Search-AzGraph, pages through
    all results (not limited to 1,000 rows), converts nested values to JSON text, and either
    writes the rows to CSV or returns them to the pipeline.

.PARAMETER QueryFile
    Path to a .kql file, for example queries/01-aks-assignments.kql.

.PARAMETER ManagementGroup
    Management group ID(s) to query. If neither ManagementGroup nor Subscription is set,
    the subscriptions available to the current Az context are used.

.PARAMETER Subscription
    Subscription ID(s) to query.

.PARAMETER OutFile
    CSV file to write. If omitted, rows are returned to the pipeline.

.EXAMPLE
    ./queries/Invoke-GraphQuery.ps1 -QueryFile ./queries/01-aks-assignments.kql -ManagementGroup contoso-mg -OutFile ./results/01-assignments.csv

.EXAMPLE
    ./queries/Invoke-GraphQuery.ps1 -QueryFile ./reporting/queries/06-noncompliance-by-namespace.kql | Format-Table
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $QueryFile,

    [string[]] $ManagementGroup,

    [string[]] $Subscription,

    [string] $OutFile
)

$ErrorActionPreference = 'Stop'

if (-not (Get-AzContext)) {
    throw 'Not signed in to Azure. Run Connect-AzAccount first.'
}

$query = (Get-Content -Path $QueryFile | Where-Object { $_ -notmatch '^\s*//' }) -join "`n"

$scope = @{}
if ($ManagementGroup) { $scope.ManagementGroup = $ManagementGroup }
elseif ($Subscription) { $scope.Subscription = $Subscription }

function ConvertTo-FlatRow {
    param($Row)
    $flat = [ordered]@{}
    foreach ($prop in $Row.PSObject.Properties) {
        $value = $prop.Value
        $isComplex = $value -is [System.Management.Automation.PSCustomObject] -or
                     $value -is [System.Collections.IDictionary] -or
                     ($value -is [System.Collections.IEnumerable] -and $value -isnot [string])
        $flat[$prop.Name] = if ($isComplex) { $value | ConvertTo-Json -Depth 20 -Compress }
                            elseif ($value -is [datetime]) { $value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ') }
                            else { $value }
    }
    [pscustomobject] $flat
}

$rows = [System.Collections.Generic.List[object]]::new()
$skipToken = $null
do {
    $request = @{ Query = $query; First = 1000 } + $scope
    if ($skipToken) { $request.SkipToken = $skipToken }
    $page = Search-AzGraph @request
    # Az.ResourceGraph 0.13+ returns an object with Data and SkipToken; older versions return rows directly.
    $hasData = $page -and ($page.PSObject.Properties.Name -contains 'Data')
    $data = if ($hasData) { $page.Data } else { $page }
    foreach ($row in $data) { $rows.Add((ConvertTo-FlatRow $row)) }
    $skipToken = if ($hasData) { $page.SkipToken } else { $null }
} while ($skipToken)

Write-Verbose "Rows: $($rows.Count)"

if ($OutFile) {
    $dir = Split-Path -Parent $OutFile
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    if ($rows.Count -eq 0) {
        Set-Content -Path $OutFile -Value 'no rows returned'
    } else {
        $rows | Export-Csv -Path $OutFile -NoTypeInformation -Encoding utf8
    }
    Write-Information "$($rows.Count) rows written to $OutFile" -InformationAction Continue
} else {
    $rows
}
