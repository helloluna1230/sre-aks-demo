<#
.SYNOPSIS
    Backwards-compatible entry point for Azure SRE Agent configuration.

.DESCRIPTION
    Delegates to configure-sre-agent-ga.ps1, which follows the current GA
    REST/ARM API setup flow from the May 2026 SRE Agent documentation and
    official starter lab.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()]
    [AllowEmptyString()]
    [string]$ResourceGroupName = '',

    [Parameter()]
    [string]$AgentName = '',

    [Parameter()]
    [string]$GitHubPat = '',

    [Parameter()]
    [string]$GitHubRepo = '',

    [Parameter()]
    [switch]$SkipKnowledgeBase,

    [Parameter()]
    [switch]$SkipAgents,

    [Parameter()]
    [switch]$SkipConnectors,

    [Parameter()]
    [switch]$SkipScheduledTasks,

    [Parameter()]
    [switch]$SkipResponsePlans,

    [Parameter()]
    [switch]$RemoveInvalidOutlookConnector,

    [Parameter()]
    [switch]$StatusOnly
)

$gaScript = Join-Path $PSScriptRoot 'configure-sre-agent-ga.ps1'
if (-not (Test-Path $gaScript)) {
    throw "Missing GA configuration script: $gaScript"
}

$arguments = @{}

if (-not [string]::IsNullOrWhiteSpace($ResourceGroupName)) { $arguments.ResourceGroupName = $ResourceGroupName.Trim() }
if ($AgentName) { $arguments.AgentName = $AgentName }
if ($GitHubPat) { $arguments.GitHubPat = $GitHubPat }
if ($GitHubRepo) { $arguments.GitHubRepo = $GitHubRepo }
if ($SkipKnowledgeBase) { $arguments.SkipKnowledgeBase = $true }
if ($SkipAgents) { $arguments.SkipAgents = $true }
if ($SkipConnectors) {
    $arguments.SkipIncidentPlatform = $true
    $arguments.SkipGitHub = $true
    $arguments.SkipOutlook = $true
}
if ($SkipScheduledTasks) { $arguments.SkipScheduledTasks = $true }
if ($SkipResponsePlans) { $arguments.SkipResponsePlans = $true }
if ($RemoveInvalidOutlookConnector) { $arguments.RemoveInvalidOutlookConnector = $true }
if ($StatusOnly) { $arguments.StatusOnly = $true }
if ($WhatIfPreference) { $arguments.WhatIf = $true }

& $gaScript @arguments
