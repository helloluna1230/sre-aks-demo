<#
.SYNOPSIS
    Configures Azure SRE Agent using the current GA-compatible REST/ARM APIs.

.DESCRIPTION
    This script aligns the sandbox with the May 2026 SRE Agent documentation and
    official starter-lab post-provision flow:

    - Uploads runbooks to Knowledge Sources through the AgentMemory upload API
    - Creates/updates custom agents through dataplane v2 ExtendedAgent APIs
    - Enables Azure Monitor as the incident platform through the ARM agent resource
    - Creates an incident response plan through the incident playground API
    - Optionally creates a GitHub OAuth connector and code repository knowledge source
    - Creates a scheduled daily AKS health-check task through the scheduled tasks API

    The script intentionally avoids a hard dependency on srectl so it can run in
    this dev container and in CI with only Azure CLI, PowerShell, curl, and Python.

.PARAMETER ResourceGroupName
    Resource group containing the Microsoft.App/agents resource.

.PARAMETER AgentName
    Optional SRE Agent resource name. If omitted, the first agent in the resource
    group is used.

.PARAMETER GitHubRepo
    Optional GitHub repository in owner/repo format. When provided, the script
    creates the GitHub OAuth connector and registers the repository as a Knowledge
    Source. GitHub tools are native/global in the GA experience, so custom agents
    do not need github-mcp/* assignments.

.PARAMETER GitHubPat
    Optional GitHub PAT kept for backwards-compatible invocation. The GA script
    does not send PATs to the API by default; use the printed OAuth URL or connect
    PAT auth in Builder > Knowledge Sources if your tenant requires PAT sign-in.

.PARAMETER SkipKnowledgeBase
    Skip runbook upload.

.PARAMETER SkipAgents
    Skip custom agent creation.

.PARAMETER SkipIncidentPlatform
    Skip enabling Azure Monitor incident platform and workspace/devops/python tools.

.PARAMETER SkipResponsePlans
    Skip incident response plan creation.

.PARAMETER SkipGitHub
    Skip GitHub OAuth/code repository setup even when GitHubRepo is provided.

.PARAMETER SkipOutlook
    Skip Outlook connector status checks and portal setup guidance.

.PARAMETER RemoveInvalidOutlookConnector
    Remove a previously script-created Outlook placeholder when no backing
    Microsoft.Web/connections OAuth connection exists. This unblocks the portal
    wizard so Outlook can be added with OAuth sign-in and managed identity.

.PARAMETER SkipScheduledTasks
    Skip scheduled task creation.

.PARAMETER SkipVerification
    Skip the final configuration summary.

.PARAMETER StatusOnly
    Do not mutate anything; only print current configuration status.

.PARAMETER IncidentAgentMode
    Autonomy mode for the incident response plan. Defaults to Review for lab safety.

.PARAMETER ResponsePlanTitleContains
    Azure Monitor incident title filter. Defaults to empty so all lab Azure Monitor
    incidents can route to incident-handler; set to 'pod' for a narrower plan.

.EXAMPLE
    ./scripts/configure-sre-agent-ga.ps1 -ResourceGroupName rg-srelab-eastus2

.EXAMPLE
    ./scripts/configure-sre-agent-ga.ps1 -ResourceGroupName rg-srelab-eastus2 -GitHubRepo owner/repo

.EXAMPLE
    ./scripts/configure-sre-agent-ga.ps1 -ResourceGroupName rg-srelab-eastus2 -StatusOnly
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()]
    [AllowEmptyString()]
    [string]$ResourceGroupName = '',

    [Parameter()]
    [string]$AgentName = '',

    [Parameter()]
    [string]$GitHubRepo = '',

    [Parameter()]
    [string]$GitHubPat = '',

    [Parameter()]
    [switch]$SkipKnowledgeBase,

    [Parameter()]
    [switch]$SkipAgents,

    [Parameter()]
    [switch]$SkipIncidentPlatform,

    [Parameter()]
    [switch]$SkipResponsePlans,

    [Parameter()]
    [switch]$SkipGitHub,

    [Parameter()]
    [switch]$SkipOutlook,

    [Parameter()]
    [switch]$RemoveInvalidOutlookConnector,

    [Parameter()]
    [switch]$SkipScheduledTasks,

    [Parameter()]
    [switch]$SkipVerification,

    [Parameter()]
    [switch]$StatusOnly,

    [Parameter()]
    [ValidateSet('Review', 'Autonomous')]
    [string]$IncidentAgentMode = 'Review',

    [Parameter()]
    [string]$ResponsePlanId = 'aks-pod-failure-handler',

    [Parameter()]
    [string]$ResponsePlanName = 'AKS Pod Failure Handler',

    [Parameter()]
    [string]$ResponsePlanTitleContains = '',

    [Parameter()]
    [string[]]$ResponsePlanSeverities = @('Sev0', 'Sev1', 'Sev2', 'Sev3', 'Sev4'),

    [Parameter()]
    [ValidateRange(0, 300)]
    [int]$IncidentPlatformInitializationDelaySeconds = 30,

    [Parameter()]
    [string]$DailyHealthCron = '0 8 * * *'
)

$ErrorActionPreference = 'Stop'

$script:ApiVersion = '2025-05-01-preview'
$script:SreTokenResource = 'https://azuresre.dev'
$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:DeploymentOutputsPath = Join-Path $script:RepoRoot 'scripts/deployment-outputs.json'
$script:AgentEndpoint = $null
$script:AgentResourceId = $null
$script:AgentResourceName = $null
$script:AgentResourceGroupName = $null

$curlCommand = Get-Command curl -CommandType Application -All -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $curlCommand) {
    throw 'curl is required to call the SRE Agent dataplane APIs.'
}
$script:CurlPath = $curlCommand.Source

function Write-Section {
    param([string]$Message)
    Write-Host "`n$Message" -ForegroundColor Yellow
}

function Test-SuccessStatusCode {
    param([int]$StatusCode)
    return $StatusCode -in @(200, 201, 202, 204, 409)
}

function ConvertTo-AgentModeValue {
    param([string]$Mode)
    if ($Mode -eq 'Autonomous') { return 'autonomous' }
    return 'review'
}

function ConvertTo-JsonBody {
    param([Parameter(Mandatory)] [object]$Body)
    return ($Body | ConvertTo-Json -Depth 30 -Compress)
}

function ConvertTo-PlainText {
    param([AllowNull()] [object[]]$Output)

    if ($null -eq $Output) {
        return ''
    }

    return (($Output | ForEach-Object {
                if ($_ -is [System.Management.Automation.ErrorRecord]) {
                    $_.Exception.Message
                }
                else {
                    [string]$_
                }
            }) -join [Environment]::NewLine).Trim()
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory)] [string]$FilePath,
        [Parameter()] [string[]]$Arguments = @()
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $FilePath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = ConvertTo-PlainText -Output $output
    }
}

function Invoke-AzJson {
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string[]]$Arguments,
        [Parameter(Mandatory)] [string]$FailureMessage
    )

    $emptyArgumentIndexes = @()
    for ($index = 0; $index -lt $Arguments.Count; $index++) {
        if ([string]::IsNullOrWhiteSpace($Arguments[$index])) {
            $emptyArgumentIndexes += $index
        }
    }

    if ($emptyArgumentIndexes.Count -gt 0) {
        $displayArguments = $Arguments | ForEach-Object { if ([string]::IsNullOrWhiteSpace($_)) { '<empty>' } else { $_ } }
        throw "Azure CLI command contains empty argument(s) at position(s) $($emptyArgumentIndexes -join ', '): az $($displayArguments -join ' ')"
    }

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & az @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($exitCode -ne 0) {
        throw "$FailureMessage`n$(ConvertTo-PlainText -Output $output)"
    }

    $text = ConvertTo-PlainText -Output $output
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    if ($text -match '^\s*\[\s*\]\s*$') {
        return @()
    }

    return $text | ConvertFrom-Json
}

function Get-DeploymentOutputValue {
    param([Parameter(Mandatory)] [string]$Name)

    if (-not (Test-Path $script:DeploymentOutputsPath)) {
        return ''
    }

    try {
        $outputs = Get-Content -Path $script:DeploymentOutputsPath -Raw | ConvertFrom-Json
        $entry = $outputs.$Name
        if ($entry -and $null -ne $entry.value) {
            return ([string]$entry.value).Trim()
        }
    }
    catch {
        Write-Host "  ⚠️  Could not read deployment outputs from $($script:DeploymentOutputsPath): $_" -ForegroundColor Yellow
    }

    return ''
}

function Resolve-ResourceGroupName {
    param([string]$Value)

    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        return $Value.Trim()
    }

    $outputResourceGroupName = Get-DeploymentOutputValue -Name 'resourceGroupName'
    if (-not [string]::IsNullOrWhiteSpace($outputResourceGroupName)) {
        Write-Host "  ℹ️  Resource group not supplied; using deployment output: $outputResourceGroupName" -ForegroundColor Gray
        return $outputResourceGroupName
    }

    throw 'ResourceGroupName was not supplied and could not be inferred from scripts/deployment-outputs.json. Pass -ResourceGroupName <name>.'
}

function Get-DeployedAgentFromOutputs {
    param(
        [Parameter(Mandatory)] [string]$EffectiveResourceGroupName,
        [string]$RequestedAgentName = ''
    )

    $outputAgentId = Get-DeploymentOutputValue -Name 'sreAgentId'
    if ([string]::IsNullOrWhiteSpace($outputAgentId)) {
        return $null
    }

    $outputResourceGroupName = Get-DeploymentOutputValue -Name 'resourceGroupName'
    if (-not [string]::IsNullOrWhiteSpace($outputResourceGroupName) -and $outputResourceGroupName -ne $EffectiveResourceGroupName) {
        return $null
    }

    $outputAgentName = Get-DeploymentOutputValue -Name 'sreAgentName'
    if ([string]::IsNullOrWhiteSpace($outputAgentName) -and $outputAgentId -match '/agents/([^/]+)$') {
        $outputAgentName = $Matches[1]
    }

    if (-not [string]::IsNullOrWhiteSpace($RequestedAgentName) -and -not [string]::IsNullOrWhiteSpace($outputAgentName) -and $outputAgentName -ne $RequestedAgentName) {
        return $null
    }

    return [pscustomobject]@{
        name = $outputAgentName
        id   = $outputAgentId
    }
}

function Get-SreAgentToken {
    $token = & az account get-access-token --resource $script:SreTokenResource --query accessToken -o tsv --only-show-errors 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
        throw "Failed to get an access token for $($script:SreTokenResource). Run az login first."
    }
    return $token.Trim()
}

function Read-CurlResponse {
    param([string[]]$Output)

    $text = ($Output | Out-String).TrimEnd()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return [pscustomobject]@{ StatusCode = 0; Body = '' }
    }

    $lines = $text -split "`n"
    $statusLine = $lines[-1].Trim()
    $statusCode = 0
    [void][int]::TryParse($statusLine, [ref]$statusCode)

    $body = ''
    if ($lines.Count -gt 1) {
        $body = ($lines[0..($lines.Count - 2)] -join "`n").Trim()
    }

    return [pscustomobject]@{
        StatusCode = $statusCode
        Body       = $body
    }
}

function Invoke-SreDataPlane {
    param(
        [Parameter(Mandatory)] [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')] [string]$Method,
        [Parameter(Mandatory)] [string]$Path,
        [Parameter()] [object]$Body = $null,
        [Parameter()] [string]$BodyJson = ''
    )

    if ([string]::IsNullOrWhiteSpace($script:AgentEndpoint)) {
        throw 'Agent endpoint has not been discovered yet.'
    }

    $token = Get-SreAgentToken
    $url = "$($script:AgentEndpoint)$Path"
    $curlArgs = @('-sS', '-w', "`n%{http_code}", '-X', $Method, $url, '-H', "Authorization: Bearer $token")
    $tempFile = $null

    try {
        if ($null -ne $Body -or -not [string]::IsNullOrWhiteSpace($BodyJson)) {
            $json = if (-not [string]::IsNullOrWhiteSpace($BodyJson)) { $BodyJson } else { ConvertTo-JsonBody -Body $Body }
            $tempFile = New-TemporaryFile
            Set-Content -Path $tempFile -Value $json -NoNewline -Encoding utf8
            $curlArgs += @('-H', 'Content-Type: application/json', '--data-binary', "@$tempFile")
        }

        $output = & $script:CurlPath @curlArgs 2>&1
        return Read-CurlResponse -Output $output
    }
    finally {
        if ($tempFile -and (Test-Path $tempFile)) {
            Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-AzureManagementRest {
    param(
        [Parameter(Mandatory)] [ValidateSet('GET', 'PUT', 'PATCH', 'DELETE')] [string]$Method,
        [Parameter(Mandatory)] [string]$ResourcePath,
        [Parameter()] [object]$Body = $null
    )

    $separator = if ($ResourcePath.Contains('?')) { '&' } else { '?' }
    $url = "https://management.azure.com$ResourcePath${separator}api-version=$($script:ApiVersion)"
    $azArgs = @('rest', '--method', $Method, '--url', $url, '--only-show-errors', '--output', 'json')
    $tempFile = $null

    try {
        if ($null -ne $Body) {
            $tempFile = New-TemporaryFile
            Set-Content -Path $tempFile -Value (ConvertTo-JsonBody -Body $Body) -NoNewline -Encoding utf8
            $azArgs += @('--body', "@$tempFile")
        }

        $previousErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $output = & az @azArgs 2>&1
            $exitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }

        if ($exitCode -ne 0) {
            throw "az rest failed for $Method $url`n$(ConvertTo-PlainText -Output $output)"
        }

        $text = ConvertTo-PlainText -Output $output
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        return $text | ConvertFrom-Json
    }
    finally {
        if ($tempFile -and (Test-Path $tempFile)) {
            Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function Initialize-SreAgentContext {
    Write-Section "🔍 Discovering Azure SRE Agent"

    $effectiveResourceGroupName = Resolve-ResourceGroupName -Value $ResourceGroupName

    $usedDeploymentOutputAgent = $false
    $agents = @(Invoke-AzJson `
            -Arguments @('resource', 'list', '--resource-group', $effectiveResourceGroupName, '--resource-type', 'Microsoft.App/agents', '--only-show-errors', '--output', 'json') `
            -FailureMessage "Could not list Microsoft.App/agents resources in $effectiveResourceGroupName.")

    if ($agents.Count -eq 0) {
        $deployedAgent = Get-DeployedAgentFromOutputs -EffectiveResourceGroupName $effectiveResourceGroupName -RequestedAgentName $AgentName
        if ($deployedAgent) {
            Write-Host '  ℹ️  Azure CLI did not list an agent in the current default subscription; using scripts/deployment-outputs.json resource ID.' -ForegroundColor Gray
            $agents = @($deployedAgent)
            $usedDeploymentOutputAgent = $true
        }
        else {
            throw "No SRE Agent found in resource group '$effectiveResourceGroupName'. Deploy the lab first or switch Azure CLI to the deployment subscription."
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($AgentName)) {
        $agents = @($agents | Where-Object { $_.name -eq $AgentName })
        if ($agents.Count -eq 0) {
            throw "SRE Agent '$AgentName' was not found in resource group '$ResourceGroupName'."
        }
    }

    if ($agents.Count -gt 1) {
        Write-Host "  ⚠️  Multiple agents found; using $($agents[0].name). Pass -AgentName to choose explicitly." -ForegroundColor Yellow
    }

    $agent = $agents[0]
    if (-not $agent -or [string]::IsNullOrWhiteSpace([string]$agent.id)) {
        throw "SRE Agent discovery returned an empty resource ID for resource group '$effectiveResourceGroupName'. Check Azure CLI subscription context and scripts/deployment-outputs.json."
    }

    $detailsFailureMessage = if ($usedDeploymentOutputAgent) {
        "Could not read SRE Agent resource details for $($agent.id). The saved SRE Agent ID in scripts/deployment-outputs.json may be stale, or the agent resource was not deployed. Confirm the resource exists in Azure, switch to the deployment subscription if needed, or redeploy with deploySreAgent enabled."
    }
    else {
        "Could not read SRE Agent resource details for $($agent.id)."
    }

    $details = Invoke-AzJson `
        -Arguments @('resource', 'show', '--ids', $agent.id, '--api-version', $script:ApiVersion, '--only-show-errors', '--output', 'json') `
        -FailureMessage $detailsFailureMessage

    $endpointCandidates = @(
        @(
            $details.properties.agentEndpoint,
            $details.properties.endpoint,
            $details.properties.defaultEndpoint,
            $details.properties.publicEndpoint
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    )

    if ($endpointCandidates.Count -eq 0) {
        throw "SRE Agent endpoint was not found on resource '$($agent.name)'. The agent may still be provisioning."
    }

    $script:AgentResourceName = $agent.name
    $script:AgentResourceId = $agent.id
    $script:AgentResourceGroupName = if ($script:AgentResourceId -match '/resourceGroups/([^/]+)/') { $Matches[1] } else { $effectiveResourceGroupName }
    $endpoint = ([string]$endpointCandidates[0]).Trim()
    if ($endpoint -notmatch '^https?://') {
        $endpoint = "https://$endpoint"
    }
    $script:AgentEndpoint = $endpoint.TrimEnd('/')

    Write-Host "  ✅ Agent:    $($script:AgentResourceName)" -ForegroundColor Green
    Write-Host "  ✅ Endpoint: $($script:AgentEndpoint)" -ForegroundColor Green
}

function Get-PythonExecutable {
    $commands = @()
    foreach ($commandName in @('python3', 'python')) {
        $commands += @(Get-Command $commandName -CommandType Application -All -ErrorAction SilentlyContinue)
    }

    foreach ($command in $commands) {
        $source = ([string]$command.Source).Trim()
        if (-not [string]::IsNullOrWhiteSpace($source) -and (Test-Path $source)) {
            return $source
        }
    }

    return $null
}

function Initialize-PythonYamlDependency {
    param([Parameter(Mandatory)] [string]$Python)

    $yamlCheck = Invoke-NativeCommand -FilePath $Python -Arguments @('-c', 'import yaml')
    if ($yamlCheck.ExitCode -ne 0) {
        Write-Host '  ℹ️  PyYAML is not available; using built-in YAML parser for repository custom-agent files.' -ForegroundColor Gray
        return $false
    }

    return $true
}

function Send-KnowledgeBaseFiles {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    if ($SkipKnowledgeBase) {
        Write-Host "`n📚 Knowledge Sources: skipped (-SkipKnowledgeBase)" -ForegroundColor Gray
        return
    }

    Write-Section '📚 Uploading runbooks to Knowledge Sources'

    $kbPath = Join-Path $script:RepoRoot 'sre-config/knowledge-base'
    $files = @(Get-ChildItem -Path $kbPath -Filter '*.md' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($files.Count -eq 0) {
        Write-Host "  ⚠️  No Markdown files found in $kbPath" -ForegroundColor Yellow
        return
    }

    if (-not $PSCmdlet.ShouldProcess("$($files.Count) knowledge files", 'Upload to SRE Agent Knowledge Sources')) {
        return
    }

    $token = Get-SreAgentToken
    $curlArgs = @(
        '-sS', '-w', "`n%{http_code}",
        '-X', 'POST', "$($script:AgentEndpoint)/api/v1/AgentMemory/upload",
        '-H', "Authorization: Bearer $token",
        '-F', 'triggerIndexing=true'
    )

    foreach ($file in $files) {
        $curlArgs += @('-F', "files=@$($file.FullName);type=text/plain")
    }

    $response = Read-CurlResponse -Output (& $script:CurlPath @curlArgs 2>&1)
    if ($response.StatusCode -in @(200, 201, 202, 204)) {
        Write-Host "  ✅ Uploaded: $($files.Name -join ', ')" -ForegroundColor Green
    }
    else {
        Write-Host "  ⚠️  Knowledge upload returned HTTP $($response.StatusCode)" -ForegroundColor Yellow
        if ($response.Body) { Write-Host "     $($response.Body.Substring(0, [Math]::Min(400, $response.Body.Length)))" -ForegroundColor Gray }
    }
}

function Convert-AgentYamlToJson {
    param(
        [Parameter(Mandatory)] [string]$YamlPath,
        [Parameter()] [AllowNull()] [string]$Python
    )

    if ([string]::IsNullOrWhiteSpace($Python)) {
        $spec = ConvertFrom-SimpleAgentYaml -YamlPath $YamlPath
        $body = ConvertTo-AgentApiEnvelope -Spec $spec
        return ConvertTo-JsonBody -Body $body
    }

    $converter = Join-Path $PSScriptRoot 'yaml-to-api-json.py'
    if (-not (Test-Path $converter)) {
        throw "Converter script not found: $converter"
    }

    $converterArgs = @($converter, $YamlPath, '-')
    if (-not [string]::IsNullOrWhiteSpace($GitHubRepo)) {
        $converterArgs += $GitHubRepo
    }

    $json = & $Python @converterArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "YAML conversion failed for $YamlPath`n$($json | Out-String)"
    }

    $text = ($json | Out-String).Trim()
    if (-not $text.StartsWith('{')) {
        throw "YAML converter did not return JSON for $YamlPath. Output: $text"
    }

    return $text
}

function Get-LeadingWhitespaceCount {
    param([string]$Line)
    if ($Line -match '^(\s*)') { return $Matches[1].Length }
    return 0
}

function ConvertTo-ScalarValue {
    param([string]$Value)

    $trimmed = $Value.Trim()
    if ($trimmed -eq 'true') { return $true }
    if ($trimmed -eq 'false') { return $false }
    if (($trimmed.StartsWith('"') -and $trimmed.EndsWith('"')) -or ($trimmed.StartsWith("'") -and $trimmed.EndsWith("'"))) {
        return $trimmed.Substring(1, $trimmed.Length - 2)
    }
    return $trimmed
}

function ConvertFrom-SimpleAgentYaml {
    param([Parameter(Mandatory)] [string]$YamlPath)

    $lines = @(Get-Content -Path $YamlPath)
    $specIndex = -1
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match '^spec\s*:\s*$') {
            $specIndex = $index
            break
        }
    }

    if ($specIndex -lt 0) {
        throw "Could not find spec: in $YamlPath"
    }

    $result = @{}
    $i = $specIndex + 1
    while ($i -lt $lines.Count) {
        $line = $lines[$i]
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith('#')) {
            $i++
            continue
        }

        if ($line -notmatch '^\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)$') {
            $i++
            continue
        }

        $key = $Matches[1]
        $value = $Matches[2].Trim()
        $keyIndent = Get-LeadingWhitespaceCount -Line $line

        if ($value -in @('|', '|-', '|+')) {
            $blockLines = @()
            $i++
            while ($i -lt $lines.Count) {
                $next = $lines[$i]
                $nextIndent = Get-LeadingWhitespaceCount -Line $next
                if ($next -match '^\s+([A-Za-z_][A-Za-z0-9_]*)\s*:' -and $nextIndent -le $keyIndent) {
                    $i--
                    break
                }
                $blockLines += $next
                $i++
            }

            $nonEmpty = @($blockLines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $minIndent = 0
            if ($nonEmpty.Count -gt 0) {
                $minIndent = ($nonEmpty | ForEach-Object { Get-LeadingWhitespaceCount -Line $_ } | Measure-Object -Minimum).Minimum
            }

            $normalized = $blockLines | ForEach-Object {
                if ($_.Length -ge $minIndent) { $_.Substring($minIndent) } else { '' }
            }
            $result[$key] = ($normalized -join "`n").TrimEnd()
        }
        elseif ($key -in @('tools', 'mcp_tools', 'handoffs', 'allowed_skills', 'tags')) {
            $items = @()
            $i++
            while ($i -lt $lines.Count) {
                $next = $lines[$i]
                $nextIndent = Get-LeadingWhitespaceCount -Line $next
                if ($next -match '^\s+([A-Za-z_][A-Za-z0-9_]*)\s*:' -and $nextIndent -le $keyIndent) {
                    $i--
                    break
                }
                if ($next -match '^\s*-\s*(.*?)\s*$') {
                    $items += (ConvertTo-ScalarValue -Value $Matches[1])
                }
                $i++
            }
            $result[$key] = $items
        }
        else {
            $result[$key] = ConvertTo-ScalarValue -Value $value
        }

        $i++
    }

    if (-not $result.ContainsKey('name')) {
        throw "Custom agent YAML is missing spec.name: $YamlPath"
    }

    return $result
}

function ConvertTo-AgentApiEnvelope {
    param([Parameter(Mandatory)] [hashtable]$Spec)

    $instructions = if ($Spec.ContainsKey('system_prompt')) { [string]$Spec.system_prompt } elseif ($Spec.ContainsKey('instructions')) { [string]$Spec.instructions } else { '' }
    $handoffDescription = if ($Spec.ContainsKey('handoff_description')) { [string]$Spec.handoff_description } elseif ($Spec.ContainsKey('handoffDescription')) { [string]$Spec.handoffDescription } else { '' }

    [object[]]$tags = @()
    if ($Spec.ContainsKey('tags') -and $null -ne $Spec.tags) {
        $tags = @($Spec.tags)
    }

    [object[]]$handoffs = @()
    if ($Spec.ContainsKey('handoffs') -and $null -ne $Spec.handoffs) {
        $handoffs = @($Spec.handoffs)
    }

    [object[]]$tools = @()
    if ($Spec.ContainsKey('tools') -and $null -ne $Spec.tools) {
        $tools = @($Spec.tools)
    }

    [object[]]$mcpTools = @()
    if ($Spec.ContainsKey('mcp_tools') -and $null -ne $Spec.mcp_tools) {
        $mcpTools = @($Spec.mcp_tools)
    }

    if (-not [string]::IsNullOrWhiteSpace($GitHubRepo)) {
        $instructions = $instructions.Replace('GITHUB_REPO_PLACEHOLDER', $GitHubRepo)
        $handoffDescription = $handoffDescription.Replace('GITHUB_REPO_PLACEHOLDER', $GitHubRepo)
    }

    $properties = [ordered]@{
        instructions           = $instructions
        handoffDescription     = $handoffDescription
        handoffs               = $handoffs
        tools                  = $tools
        mcpTools               = $mcpTools
        allowParallelToolCalls = if ($Spec.ContainsKey('allow_parallel_tool_calls')) { [bool]$Spec.allow_parallel_tool_calls } else { $true }
    }

    if ($Spec.ContainsKey('allowed_skills')) {
        [object[]]$allowedSkills = @()
        if ($null -ne $Spec.allowed_skills) {
            $allowedSkills = @($Spec.allowed_skills)
        }
        $properties.allowedSkills = $allowedSkills
    }
    elseif ($Spec.ContainsKey('enable_skills')) {
        $properties.enableSkills = [bool]$Spec.enable_skills
    }

    return [ordered]@{
        name       = [string]$Spec.name
        type       = 'ExtendedAgent'
        tags       = $tags
        owner      = if ($Spec.ContainsKey('owner')) { [string]$Spec.owner } else { '' }
        properties = $properties
    }
}

function Set-CustomAgents {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    if ($SkipAgents) {
        Write-Host "`n🤖 Custom agents: skipped (-SkipAgents)" -ForegroundColor Gray
        return
    }

    Write-Section '🤖 Creating/updating custom agents'

    $python = Get-PythonExecutable
    if (-not [string]::IsNullOrWhiteSpace([string]$python)) {
        $python = ([string]$python).Trim()
        if (-not (Initialize-PythonYamlDependency -Python $python)) {
            $python = $null
        }
    }
    else {
        Write-Host '  ℹ️  Python not found; using built-in parser for repository custom-agent YAML.' -ForegroundColor Gray
    }

    $agentsDir = Join-Path $script:RepoRoot 'sre-config/agents'
    $agentFiles = @()

    if (-not [string]::IsNullOrWhiteSpace($GitHubRepo) -and -not $SkipGitHub) {
        Write-Host '  🔗 GitHub repo supplied — using GitHub-aware incident workflow' -ForegroundColor Gray
        $agentFiles += Join-Path $agentsDir 'incident-handler-full.yaml'
        $agentFiles += Join-Path $agentsDir 'code-analyzer.yaml'
    }
    else {
        Write-Host '  📋 No GitHub repo supplied — using core incident workflow' -ForegroundColor Gray
        $agentFiles += Join-Path $agentsDir 'incident-handler-core.yaml'
    }

    $agentFiles += Join-Path $agentsDir 'cluster-health-monitor.yaml'

    foreach ($yamlFile in $agentFiles) {
        if (-not (Test-Path $yamlFile)) {
            Write-Host "  ⚠️  Missing agent file: $(Split-Path $yamlFile -Leaf)" -ForegroundColor Yellow
            continue
        }

        $jsonBody = Convert-AgentYamlToJson -YamlPath $yamlFile -Python $python
        $agentSpec = $jsonBody | ConvertFrom-Json
        $customAgentName = $agentSpec.name

        if (-not $PSCmdlet.ShouldProcess($customAgentName, 'Create/update custom agent')) {
            continue
        }

        $response = Invoke-SreDataPlane -Method PUT -Path "/api/v2/extendedAgent/agents/$customAgentName" -BodyJson $jsonBody
        if (Test-SuccessStatusCode -StatusCode $response.StatusCode) {
            Write-Host "  ✅ $customAgentName" -ForegroundColor Green
        }
        else {
            Write-Host "  ⚠️  $customAgentName returned HTTP $($response.StatusCode)" -ForegroundColor Yellow
            if ($response.Body) { Write-Host "     $($response.Body.Substring(0, [Math]::Min(400, $response.Body.Length)))" -ForegroundColor Gray }
        }
    }
}

function Enable-AzureMonitorIncidentPlatform {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    if ($SkipIncidentPlatform) {
        Write-Host "`n🚨 Azure Monitor incident platform: skipped (-SkipIncidentPlatform)" -ForegroundColor Gray
        return
    }

    Write-Section '🚨 Enabling Azure Monitor incident platform and built-in tools'

    $patchBody = @{
        properties = @{
            incidentManagementConfiguration = @{
                type           = 'AzMonitor'
                connectionName = 'azmonitor'
            }
            experimentalSettings            = @{
                EnableWorkspaceTools = $true
                EnableDevOpsTools    = $true
                EnablePythonTools    = $true
            }
        }
    }

    if ($PSCmdlet.ShouldProcess($script:AgentResourceName, 'Enable Azure Monitor incident platform')) {
        Invoke-AzureManagementRest -Method PATCH -ResourcePath $script:AgentResourceId -Body $patchBody | Out-Null
        Write-Host '  ✅ Azure Monitor incident platform enabled' -ForegroundColor Green
        Write-Host '  ✅ Workspace, DevOps, and Python tools enabled' -ForegroundColor Green

        if ($IncidentPlatformInitializationDelaySeconds -gt 0 -and -not $WhatIfPreference) {
            Write-Host "  ⏳ Waiting $IncidentPlatformInitializationDelaySeconds seconds for incident platform initialization..." -ForegroundColor Gray
            Start-Sleep -Seconds $IncidentPlatformInitializationDelaySeconds
        }
    }
}

function Set-ResponsePlan {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    if ($SkipResponsePlans) {
        Write-Host "`n🚨 Incident response plan: skipped (-SkipResponsePlans)" -ForegroundColor Gray
        return
    }

    Write-Section '🚨 Creating/updating incident response plan'

    if ($PSCmdlet.ShouldProcess('quickstart_response_plan', 'Delete default response plan if present')) {
        Invoke-SreDataPlane -Method DELETE -Path '/api/v1/incidentPlayground/filters/quickstart_response_plan' | Out-Null
    }

    $body = @{
        id            = $ResponsePlanId
        name          = $ResponsePlanName
        priorities    = $ResponsePlanSeverities
        titleContains = $ResponsePlanTitleContains
        handlingAgent = 'incident-handler'
        agentMode     = ConvertTo-AgentModeValue -Mode $IncidentAgentMode
        maxAttempts   = 3
    }

    if (-not $PSCmdlet.ShouldProcess($ResponsePlanName, 'Create/update incident response plan')) {
        return
    }

    $response = Invoke-SreDataPlane -Method PUT -Path "/api/v1/incidentPlayground/filters/$ResponsePlanId" -Body $body
    if (Test-SuccessStatusCode -StatusCode $response.StatusCode) {
        $filterText = if ([string]::IsNullOrWhiteSpace($ResponsePlanTitleContains)) { 'all Azure Monitor incidents' } else { "titles containing '$ResponsePlanTitleContains'" }
        Write-Host "  ✅ $ResponsePlanName → incident-handler ($filterText, mode: $IncidentAgentMode)" -ForegroundColor Green
    }
    else {
        Write-Host "  ⚠️  Response plan returned HTTP $($response.StatusCode)" -ForegroundColor Yellow
        if ($response.Body) { Write-Host "     $($response.Body.Substring(0, [Math]::Min(400, $response.Body.Length)))" -ForegroundColor Gray }
    }
}

function Get-OutlookConnectorFromDataPlane {
    try {
        $response = Invoke-SreDataPlane -Method GET -Path '/api/v2/extendedAgent/connectors/outlook'
        if ($response.StatusCode -eq 200 -and -not [string]::IsNullOrWhiteSpace($response.Body)) {
            return ($response.Body | ConvertFrom-Json)
        }
    }
    catch {
        Write-Host "  ⚠️  Could not inspect dataplane Outlook connector: $_" -ForegroundColor Yellow
    }

    return $null
}

function Get-OutlookBackingConnections {
    if ([string]::IsNullOrWhiteSpace($script:AgentResourceGroupName)) {
        return @()
    }

    try {
        $connections = @(Invoke-AzJson `
                -Arguments @('resource', 'list', '--resource-group', $script:AgentResourceGroupName, '--resource-type', 'Microsoft.Web/connections', '--only-show-errors', '--output', 'json') `
                -FailureMessage "Could not list Microsoft.Web/connections resources in $($script:AgentResourceGroupName).")

        return @($connections | Where-Object {
                $name = [string]$_.name
                $displayName = [string]$_.properties.displayName
                $apiId = [string]$_.properties.api.id
                $name -match '(?i)outlook|office365' -or $displayName -match '(?i)outlook|office365' -or $apiId -match '(?i)outlook|office365'
            })
    }
    catch {
        Write-Host "  ⚠️  Could not inspect Outlook backing connections: $_" -ForegroundColor Yellow
        return @()
    }
}

function Remove-OutlookConnectorPlaceholder {
    $removed = $false

    if ($PSCmdlet.ShouldProcess('outlook', 'Delete dataplane Outlook connector placeholder')) {
        try {
            $response = Invoke-SreDataPlane -Method DELETE -Path '/api/v2/extendedAgent/connectors/outlook'
            if ($response.StatusCode -in @(200, 202, 204, 404)) {
                Write-Host '  ✅ Removed dataplane Outlook connector placeholder' -ForegroundColor Green
                $removed = $true
            }
            else {
                Write-Host "  ⚠️  Dataplane Outlook connector delete returned HTTP $($response.StatusCode)" -ForegroundColor Yellow
                if ($response.Body) { Write-Host "     $($response.Body.Substring(0, [Math]::Min(400, $response.Body.Length)))" -ForegroundColor Gray }
            }
        }
        catch {
            Write-Host "  ⚠️  Could not delete dataplane Outlook connector placeholder: $_" -ForegroundColor Yellow
        }
    }

    if ($PSCmdlet.ShouldProcess('outlook', 'Delete ARM Outlook connector placeholder')) {
        try {
            Invoke-AzureManagementRest -Method DELETE -ResourcePath "$($script:AgentResourceId)/connectors/outlook" | Out-Null
            Write-Host '  ✅ Removed ARM Outlook connector placeholder' -ForegroundColor Green
            $removed = $true
        }
        catch {
            $message = [string]$_
            if ($message -match 'ResourceNotFound|NotFound|404') {
                Write-Host '  ℹ️  ARM Outlook connector placeholder was already absent' -ForegroundColor Gray
            }
            else {
                Write-Host "  ⚠️  Could not delete ARM Outlook connector placeholder: $_" -ForegroundColor Yellow
            }
        }
    }

    return $removed
}

function Set-OutlookConnector {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    if ($SkipOutlook) {
        Write-Host "`n📧 Outlook connector: skipped (-SkipOutlook)" -ForegroundColor Gray
        return
    }

    Write-Section '📧 Outlook connector setup'

    $connector = Get-OutlookConnectorFromDataPlane
    $backingConnections = @(Get-OutlookBackingConnections)

    if ($connector -and $backingConnections.Count -eq 0) {
        Write-Host '  ⚠️  Found an Outlook connector record, but no Microsoft.Web/connections Outlook OAuth backing resource.' -ForegroundColor Yellow
        Write-Host "     This is the broken placeholder state that causes: Name='', Type='Outlook', DataSource=''" -ForegroundColor Gray

        if ($RemoveInvalidOutlookConnector) {
            [void](Remove-OutlookConnectorPlaceholder)
            Write-Host '  📌 Now add Outlook from the portal: https://sre.azure.com → Builder → Connectors → Add connector → Outlook Tools (Office 365 Outlook)' -ForegroundColor Gray
            Write-Host '     Complete OAuth sign-in and select a managed identity. The portal creates the required Microsoft.Web/connections resource.' -ForegroundColor Gray
        }
        else {
            Write-Host '  📌 Delete this Outlook connector in the portal, or rerun this script with -RemoveInvalidOutlookConnector.' -ForegroundColor Gray
            Write-Host '     Then add Outlook from Builder → Connectors using the OAuth wizard.' -ForegroundColor Gray
        }

        return
    }

    if ($connector -and $backingConnections.Count -gt 0) {
        Write-Host "  ✅ Outlook connector record found with backing connection: $($backingConnections[0].name)" -ForegroundColor Green
        Write-Host '  📌 If email still fails, edit the connector in the portal and reauthenticate Outlook.' -ForegroundColor Gray
        return
    }

    Write-Host '  ℹ️  Outlook connectors require portal OAuth sign-in and managed identity selection.' -ForegroundColor Gray
    Write-Host '     This script intentionally does not create Outlook OAuth connectors programmatically.' -ForegroundColor Gray
    Write-Host '  📌 Add Outlook from: https://sre.azure.com → Builder → Connectors → Add connector → Outlook Tools (Office 365 Outlook)' -ForegroundColor Gray
}

function Set-GitHubKnowledgeSource {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    if ($SkipGitHub -or [string]::IsNullOrWhiteSpace($GitHubRepo)) {
        Write-Host "`n🔗 GitHub knowledge source: skipped" -ForegroundColor Gray
        return
    }

    if ($GitHubRepo -notmatch '^[^/\s]+/[^/\s]+$') {
        throw "GitHubRepo must use owner/repo format. Received: '$GitHubRepo'"
    }

    Write-Section '🔗 Configuring GitHub OAuth connector and code repository knowledge source'

    if (-not [string]::IsNullOrWhiteSpace($GitHubPat)) {
        Write-Host '  ℹ️  GitHubPat was provided for backwards compatibility.' -ForegroundColor Gray
        Write-Host '     GA setup uses GitHub OAuth / Knowledge Sources; this script will not print or send the PAT.' -ForegroundColor Gray
    }

    $connectorBody = @{
        name       = 'github'
        type       = 'AgentConnector'
        properties = @{
            dataConnectorType = 'GitHubOAuth'
            dataSource        = 'github-oauth'
        }
    }

    if ($PSCmdlet.ShouldProcess('github', 'Create/update GitHub OAuth connector via dataplane')) {
        $response = Invoke-SreDataPlane -Method PUT -Path '/api/v2/extendedAgent/connectors/github' -Body $connectorBody
        if (Test-SuccessStatusCode -StatusCode $response.StatusCode) {
            Write-Host '  ✅ GitHub OAuth connector created via dataplane' -ForegroundColor Green
        }
        else {
            Write-Host "  ⚠️  Dataplane GitHub connector returned HTTP $($response.StatusCode)" -ForegroundColor Yellow
        }
    }

    if ($PSCmdlet.ShouldProcess('github', 'Create/update GitHub OAuth connector via ARM DataConnectors')) {
        $armBody = @{
            properties = @{
                dataConnectorType = 'GitHubOAuth'
                dataSource        = 'github-oauth'
            }
        }
        Invoke-AzureManagementRest -Method PUT -ResourcePath "$($script:AgentResourceId)/DataConnectors/github" -Body $armBody | Out-Null
        Write-Host '  ✅ GitHub OAuth connector created via ARM' -ForegroundColor Green
    }

    $oauthUrl = ''
    try {
        $config = Invoke-SreDataPlane -Method GET -Path '/api/v1/github/config'
        if ($config.StatusCode -eq 200 -and $config.Body) {
            $configJson = $config.Body | ConvertFrom-Json
            $oauthUrl = if ($configJson.oAuthUrl) { $configJson.oAuthUrl } elseif ($configJson.OAuthUrl) { $configJson.OAuthUrl } else { '' }
        }
    }
    catch {
        Write-Host "  ⚠️  Could not fetch GitHub OAuth URL: $_" -ForegroundColor Yellow
    }

    $repoName = ($GitHubRepo -split '/')[-1]
    $repoBody = @{
        name       = $repoName
        type       = 'CodeRepo'
        properties = @{
            url               = "https://github.com/$GitHubRepo"
            authConnectorName = 'github'
        }
    }

    if ($PSCmdlet.ShouldProcess($GitHubRepo, 'Register GitHub repository as a Knowledge Source')) {
        $response = Invoke-SreDataPlane -Method PUT -Path "/api/v2/repos/$repoName" -Body $repoBody
        if (Test-SuccessStatusCode -StatusCode $response.StatusCode) {
            Write-Host "  ✅ Code repository knowledge source: $GitHubRepo" -ForegroundColor Green
        }
        else {
            Write-Host "  ⚠️  Code repository registration returned HTTP $($response.StatusCode)" -ForegroundColor Yellow
            if ($response.Body) { Write-Host "     $($response.Body.Substring(0, [Math]::Min(400, $response.Body.Length)))" -ForegroundColor Gray }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($oauthUrl)) {
        Write-Host ''
        Write-Host '  GitHub authorization required:' -ForegroundColor Yellow
        Write-Host "  $oauthUrl" -ForegroundColor White
        Write-Host '  Open the URL, authorize access, then rerun with -StatusOnly to verify indexing.' -ForegroundColor Gray
    }
    else {
        Write-Host '  ℹ️  OAuth URL was not returned. Authorize GitHub from Builder > Knowledge Sources if needed.' -ForegroundColor Gray
    }
}

function Set-ScheduledHealthCheck {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    if ($SkipScheduledTasks) {
        Write-Host "`n⏰ Scheduled task: skipped (-SkipScheduledTasks)" -ForegroundColor Gray
        return
    }

    Write-Section '⏰ Creating/updating scheduled AKS health check'

    $existingTasksResponse = Invoke-SreDataPlane -Method GET -Path '/api/v1/scheduledtasks'
    if ($existingTasksResponse.StatusCode -eq 200 -and $existingTasksResponse.Body) {
        try {
            $existingTasks = @($existingTasksResponse.Body | ConvertFrom-Json)
            foreach ($task in ($existingTasks | Where-Object { $_.name -eq 'daily-health-check' })) {
                if ($task.id -and $PSCmdlet.ShouldProcess($task.id, 'Delete existing scheduled task before recreating')) {
                    Invoke-SreDataPlane -Method DELETE -Path "/api/v1/scheduledtasks/$($task.id)" | Out-Null
                }
            }
        }
        catch {
            Write-Host "  ⚠️  Could not parse existing scheduled tasks: $_" -ForegroundColor Yellow
        }
    }

    $body = @{
        name           = 'daily-health-check'
        description    = 'Daily AKS health check for the pets namespace and sandbox resources'
        cronExpression = $DailyHealthCron
        agentPrompt    = 'Use the cluster-health-monitor custom agent to run a comprehensive health check of the AKS cluster and the pets namespace. Check pod status, recent restarts, OOMKilled events, CrashLoopBackOff, ImagePullBackOff, probe failures, pending pods, resource pressure, service endpoints, dependency health for MongoDB/RabbitMQ, and error trends. Summarize overall status, evidence, likely risks, and recommended next actions.'
        agent          = 'cluster-health-monitor'
        agentMode      = 'autonomous'
    }

    if (-not $PSCmdlet.ShouldProcess('daily-health-check', 'Create scheduled task')) {
        return
    }

    $response = Invoke-SreDataPlane -Method POST -Path '/api/v1/scheduledtasks' -Body $body
    if (Test-SuccessStatusCode -StatusCode $response.StatusCode) {
        Write-Host "  ✅ daily-health-check ($DailyHealthCron UTC) → cluster-health-monitor" -ForegroundColor Green
    }
    else {
        Write-Host "  ⚠️  Scheduled task returned HTTP $($response.StatusCode)" -ForegroundColor Yellow
        if ($response.Body) { Write-Host "     $($response.Body.Substring(0, [Math]::Min(400, $response.Body.Length)))" -ForegroundColor Gray }
    }
}

function Show-ConfigurationStatus {
    Write-Section '📋 Current SRE Agent configuration'

    $token = Get-SreAgentToken

    Write-Host '  📚 Knowledge Sources:' -ForegroundColor Cyan
    try {
        $files = Invoke-SreDataPlane -Method GET -Path '/api/v1/AgentMemory/files'
        if ($files.StatusCode -eq 200 -and $files.Body) {
            $data = $files.Body | ConvertFrom-Json
            $items = @($data.files)
            if ($items.Count -eq 0) { Write-Host '     (none)' -ForegroundColor Gray }
            foreach ($file in $items) {
                $status = if ($file.isIndexed) { '✅' } else { '⏳' }
                Write-Host "     $status $($file.name)" -ForegroundColor Gray
            }
        }
        else { Write-Host "     unavailable (HTTP $($files.StatusCode))" -ForegroundColor Gray }
    }
    catch { Write-Host "     unavailable: $_" -ForegroundColor Gray }

    Write-Host '  🤖 Custom Agents:' -ForegroundColor Cyan
    try {
        $agents = Invoke-SreDataPlane -Method GET -Path '/api/v2/extendedAgent/agents'
        if ($agents.StatusCode -eq 200 -and $agents.Body) {
            $data = $agents.Body | ConvertFrom-Json
            $items = @($data.value)
            if ($items.Count -eq 0) { Write-Host '     (none)' -ForegroundColor Gray }
            foreach ($agent in $items) {
                $toolCount = @($agent.properties.tools).Count + @($agent.properties.mcpTools).Count
                Write-Host "     ✅ $($agent.name) ($toolCount tools)" -ForegroundColor Gray
            }
        }
        else { Write-Host "     unavailable (HTTP $($agents.StatusCode))" -ForegroundColor Gray }
    }
    catch { Write-Host "     unavailable: $_" -ForegroundColor Gray }

    Write-Host '  🔗 Connectors:' -ForegroundColor Cyan
    try {
        $connectors = Invoke-AzureManagementRest -Method GET -ResourcePath "$($script:AgentResourceId)/DataConnectors"
        $items = @($connectors.value)
        if ($items.Count -eq 0) { Write-Host '     (none)' -ForegroundColor Gray }
        foreach ($connector in $items) {
            $state = if ($connector.properties.provisioningState) { $connector.properties.provisioningState } else { 'Unknown' }
            $icon = if ($state -eq 'Succeeded') { '✅' } else { '⏳' }
            Write-Host "     $icon $($connector.name) ($state)" -ForegroundColor Gray
        }
    }
    catch { Write-Host "     unavailable: $_" -ForegroundColor Gray }

    Write-Host '  📡 Incident Platform:' -ForegroundColor Cyan
    try {
        $platform = Invoke-SreDataPlane -Method GET -Path '/api/v1/incidentPlayground/incidentPlatformType'
        if ($platform.StatusCode -eq 200 -and $platform.Body) {
            $data = $platform.Body | ConvertFrom-Json
            $platformType = if ($data.incidentPlatformType) { $data.incidentPlatformType } else { [string]$data }
            $display = if ($platformType -eq 'AzMonitor') { 'Azure Monitor' } else { $platformType }
            Write-Host "     ✅ $display" -ForegroundColor Gray
        }
        else { Write-Host "     unavailable (HTTP $($platform.StatusCode))" -ForegroundColor Gray }
    }
    catch { Write-Host "     unavailable: $_" -ForegroundColor Gray }

    Write-Host '  🚨 Response Plans:' -ForegroundColor Cyan
    try {
        $filters = Invoke-SreDataPlane -Method GET -Path '/api/v1/incidentPlayground/filters'
        if ($filters.StatusCode -eq 200 -and $filters.Body) {
            $items = @($filters.Body | ConvertFrom-Json)
            if ($items.Count -eq 0) { Write-Host '     (none)' -ForegroundColor Gray }
            foreach ($filter in $items) {
                $handler = if ($filter.handlingAgent) { $filter.handlingAgent } else { '(none)' }
                Write-Host "     ✅ $($filter.id) → $handler" -ForegroundColor Gray
            }
        }
        else { Write-Host "     unavailable (HTTP $($filters.StatusCode))" -ForegroundColor Gray }
    }
    catch { Write-Host "     unavailable: $_" -ForegroundColor Gray }

    Write-Host '  ⏰ Scheduled Tasks:' -ForegroundColor Cyan
    try {
        $tasks = Invoke-SreDataPlane -Method GET -Path '/api/v1/scheduledtasks'
        if ($tasks.StatusCode -eq 200 -and $tasks.Body) {
            $items = @($tasks.Body | ConvertFrom-Json)
            if ($items.Count -eq 0) { Write-Host '     (none)' -ForegroundColor Gray }
            foreach ($task in $items) {
                $status = if ($task.status) { $task.status } else { 'Unknown' }
                $handler = if ($task.agent) { $task.agent } else { '(main agent)' }
                Write-Host "     ✅ $($task.name) ($($task.cronExpression), $status) → $handler" -ForegroundColor Gray
            }
        }
        else { Write-Host "     unavailable (HTTP $($tasks.StatusCode))" -ForegroundColor Gray }
    }
    catch { Write-Host "     unavailable: $_" -ForegroundColor Gray }

    [void]$token
}

Write-Host @"

╔══════════════════════════════════════════════════════════════════════════════╗
║       Azure SRE Agent Configuration — GA REST/ARM API (May 2026)             ║
╚══════════════════════════════════════════════════════════════════════════════╝
"@ -ForegroundColor Cyan

Initialize-SreAgentContext

if ($StatusOnly) {
    Show-ConfigurationStatus
    return
}

Send-KnowledgeBaseFiles
Set-CustomAgents
Enable-AzureMonitorIncidentPlatform
Set-ResponsePlan
Set-OutlookConnector
Set-GitHubKnowledgeSource
Set-ScheduledHealthCheck

if (-not $SkipVerification) {
    Show-ConfigurationStatus
}

Write-Host @"

╔══════════════════════════════════════════════════════════════════════════════╗
║                  SRE Agent configuration complete 🎉                         ║
╚══════════════════════════════════════════════════════════════════════════════╝

Portal: https://sre.azure.com
Next:   Apply a scenario such as break-oom, then ask:
        "Why are pods crashing in the pets namespace?"
"@ -ForegroundColor Cyan
