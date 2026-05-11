<#
.SYNOPSIS
    Deprecated compatibility wrapper for configure-sre-agent-ga.ps1.
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

$script = Join-Path $PSScriptRoot 'configure-sre-agent.ps1'
$arguments = @{}

if (-not [string]::IsNullOrWhiteSpace($ResourceGroupName)) { $arguments.ResourceGroupName = $ResourceGroupName.Trim() }
if ($AgentName) { $arguments.AgentName = $AgentName }
if ($GitHubPat) { $arguments.GitHubPat = $GitHubPat }
if ($GitHubRepo) { $arguments.GitHubRepo = $GitHubRepo }
if ($SkipKnowledgeBase) { $arguments.SkipKnowledgeBase = $true }
if ($SkipAgents) { $arguments.SkipAgents = $true }
if ($SkipConnectors) { $arguments.SkipConnectors = $true }
if ($SkipScheduledTasks) { $arguments.SkipScheduledTasks = $true }
if ($SkipResponsePlans) { $arguments.SkipResponsePlans = $true }
if ($RemoveInvalidOutlookConnector) { $arguments.RemoveInvalidOutlookConnector = $true }
if ($StatusOnly) { $arguments.StatusOnly = $true }
if ($WhatIfPreference) { $arguments.WhatIf = $true }

& $script @arguments
