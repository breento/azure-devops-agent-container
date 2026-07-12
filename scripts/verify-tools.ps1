$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$requiredCommands = @('az', 'git', 'jq', 'packer', 'pwsh', 'terraform')
$requiredModules = @(
    'Az.Accounts',
    'Az.Resources',
    'Az.Storage',
    'Az.Compute',
    'Az.Network',
    'Az.ManagedServiceIdentity',
    'Az.DesktopVirtualization'
)

foreach ($command in $requiredCommands) {
    if (-not (Get-Command -Name $command -ErrorAction SilentlyContinue)) {
        throw "Required command '$command' was not found."
    }
}

foreach ($extension in @('azure-devops', 'containerapp')) {
    az extension show --name $extension --only-show-errors | Out-Null
}

$installedModules = @{}
foreach ($module in $requiredModules) {
    $installed = Get-Module -ListAvailable -Name $module | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $installed) {
        throw "Required PowerShell module '$module' was not found."
    }

    Import-Module -Name $module -ErrorAction Stop
    $installedModules[$module] = $installed.Version
}

Write-Host "PowerShell: $($PSVersionTable.PSVersion)"
Write-Host "Azure CLI: $((az version --output json | ConvertFrom-Json).'azure-cli')"
Write-Host "Terraform: $((terraform version -json | ConvertFrom-Json).terraform_version)"
Write-Host "Packer: $((packer version).Trim())"
Write-Host "Git: $((git --version).Trim())"
Write-Host 'PowerShell modules:'
foreach ($module in $requiredModules) {
    Write-Host "  $module $($installedModules[$module])"
}
