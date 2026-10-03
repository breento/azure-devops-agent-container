$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$runtimeArchitecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
$expectedArchitecture = switch ($runtimeArchitecture) {
    'x64' { 'amd64' }
    'arm64' { 'arm64' }
    default { throw "Unsupported runtime architecture '$runtimeArchitecture'." }
}
if ($env:TARGETARCH -and $env:TARGETARCH -ne $expectedArchitecture) {
    throw "Runtime architecture '$expectedArchitecture' does not match build target '$env:TARGETARCH'."
}
Write-Host "OS/runtime architecture: Linux/$expectedArchitecture ($runtimeArchitecture)"

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
    $extensionInfo = az extension show --name $extension --only-show-errors | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or -not $extensionInfo.version) {
        throw "Azure CLI extension '$extension' is not installed correctly."
    }
    Write-Host "Azure CLI extension: $extension $($extensionInfo.version)"
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
Write-Host 'Azure CLI extensions: azure-devops, containerapp'
Write-Host "Terraform: $((terraform version -json | ConvertFrom-Json).terraform_version)"
Write-Host "Packer: $((packer version).Trim())"
$agentListener = '/azp/agent/bin/Agent.Listener'
if (-not (Test-Path -LiteralPath $agentListener -PathType Leaf)) {
    throw "Azure DevOps agent listener was not found at '$agentListener'."
}
$agentVersion = (& $agentListener --version).Trim()
if ($LASTEXITCODE -ne 0 -or ($env:AZP_AGENT_VERSION -and $agentVersion -ne $env:AZP_AGENT_VERSION)) {
    throw "Azure DevOps agent version '$agentVersion' does not match pinned version '$($env:AZP_AGENT_VERSION)'."
}
Write-Host "Azure DevOps agent: $agentVersion"
Write-Host "Git: $((git --version).Trim())"
Write-Host 'PowerShell modules:'
foreach ($module in $requiredModules) {
    Write-Host "  $module $($installedModules[$module])"
}
