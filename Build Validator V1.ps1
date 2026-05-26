<#
.SYNOPSIS
Build Validator - v1

.DESCRIPTION
A lightweight PowerShell WPF tool for validating a newly built Windows device before handover.
It combines automated endpoint checks with a manual technician checklist and exports an HTML report.

This is intended as a personal/lab portfolio project and does not contain employer-specific logic.

.NOTES
Run as Administrator for best results.
PowerShell 5.1+ recommended.
#>

if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator))
{
    Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

try {
    Add-Type -AssemblyName System.Web -ErrorAction Stop
}
catch {
    # Fallback is handled by ConvertTo-HtmlSafe if System.Web is unavailable.
}

# -----------------------------
# Global state
# -----------------------------
$script:AutomatedResults = @()
$script:ManualChecks = @()

$ReportsPath = Join-Path -Path $PSScriptRoot -ChildPath "Reports"
if (-not (Test-Path $ReportsPath)) {
    New-Item -ItemType Directory -Path $ReportsPath -Force | Out-Null
}

# -----------------------------
# Helper functions
# -----------------------------
function New-Result {
    param(
        [string]$Name,
        [ValidateSet("Pass", "Warning", "Fail")]
        [string]$Status,
        [string]$Details,
        [string]$Recommendation = "No action required."
    )

    [PSCustomObject]@{
        Name           = $Name
        Status         = $Status
        Details        = $Details
        Recommendation = $Recommendation
    }
}

function Get-StatusIcon {
    param([string]$Status)

    switch ($Status) {
        "Pass"    { "✅" }
        "Warning" { "⚠️" }
        "Fail"    { "❌" }
        default    { "ℹ️" }
    }
}

function Get-StatusBrush {
    param([string]$Status)

    switch ($Status) {
        "Pass"    { "#107C10" }
        "Warning" { "#FFB900" }
        "Fail"    { "#D13438" }
        default    { "#666666" }
    }
}

function ConvertTo-HtmlSafe {
    param([AllowNull()][string]$Text)

    if ($null -eq $Text) { return "" }

    try {
        return [System.Web.HttpUtility]::HtmlEncode($Text)
    }
    catch {
        return [System.Security.SecurityElement]::Escape($Text)
    }
}

function Test-PendingReboot {
    $paths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired",
        "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager"
    )

    if (Test-Path $paths[0]) { return $true }
    if (Test-Path $paths[1]) { return $true }

    try {
        $pendingFileRename = Get-ItemProperty -Path $paths[2] -Name "PendingFileRenameOperations" -ErrorAction SilentlyContinue
        if ($pendingFileRename) { return $true }
    }
    catch { }

    return $false
}

function Run-AutomatedChecks {
    $results = @()

    # Device name
    $results += New-Result -Name "Device Name" -Status "Pass" -Details $env:COMPUTERNAME

    # OS version
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $results += New-Result -Name "Windows Version" -Status "Pass" -Details "$($os.Caption) - Build $($os.BuildNumber)"
    }
    catch {
        $results += New-Result -Name "Windows Version" -Status "Warning" -Details "Unable to query OS details."
    }

    # Disk space
    try {
        $systemDrive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
        $freeGB = [math]::Round($systemDrive.FreeSpace / 1GB, 2)
        $totalGB = [math]::Round($systemDrive.Size / 1GB, 2)

        if ($freeGB -ge 20) {
            $results += New-Result -Name "Disk Space" -Status "Pass" -Details "C: has $freeGB GB free of $totalGB GB."
        }
        elseif ($freeGB -ge 10) {
            $results += New-Result -Name "Disk Space" -Status "Warning" -Details "C: has only $freeGB GB free of $totalGB GB." -Recommendation "Free up disk space before handover. Aim for at least 20 GB free."
        }
        else {
            $results += New-Result -Name "Disk Space" -Status "Fail" -Details "C: has critically low free space: $freeGB GB free of $totalGB GB." -Recommendation "Resolve low disk space before handover."
        }
    }
    catch {
        $results += New-Result -Name "Disk Space" -Status "Warning" -Details "Unable to query disk space."
    }

    # Pending reboot
    try {
        if (Test-PendingReboot) {
            $results += New-Result -Name "Pending Reboot" -Status "Warning" -Details "A pending reboot was detected." -Recommendation "Restart the device before handover and re-run validation."
        }
        else {
            $results += New-Result -Name "Pending Reboot" -Status "Pass" -Details "No pending reboot detected."
        }
    }
    catch {
        $results += New-Result -Name "Pending Reboot" -Status "Warning" -Details "Unable to check pending reboot status."
    }

    # BitLocker
    try {
        $bitlocker = Get-BitLockerVolume -MountPoint "C:" -ErrorAction Stop
        if ($bitlocker.ProtectionStatus -eq "On") {
            $results += New-Result -Name "BitLocker" -Status "Pass" -Details "BitLocker protection is enabled on C:."
        }
        elseif ($bitlocker.VolumeStatus -like "EncryptionInProgress*") {
            $results += New-Result -Name "BitLocker" -Status "Warning" -Details "BitLocker encryption is in progress."
        }
        else {
            $results += New-Result -Name "BitLocker" -Status "Fail" -Details "BitLocker protection is not enabled on C:." -Recommendation "Enable BitLocker or confirm encryption is intentionally excluded for this device."
        }
    }
    catch {
        $results += New-Result -Name "BitLocker" -Status "Warning" -Details "Unable to query BitLocker. Run as Administrator or check Windows edition."
    }

    # TPM
    try {
        $tpm = Get-Tpm -ErrorAction Stop

        if ($tpm.TpmPresent -and $tpm.TpmReady) {
            $results += New-Result -Name "TPM" -Status "Pass" -Details "TPM is present and ready."
        }
        elseif ($tpm.TpmPresent) {
            $details = "TPM is present, but Windows reports it is not fully ready. Present=$($tpm.TpmPresent), Ready=$($tpm.TpmReady), Enabled=$($tpm.TpmEnabled), Activated=$($tpm.TpmActivated), Owned=$($tpm.TpmOwned)."
            $results += New-Result -Name "TPM" -Status "Warning" -Details $details
        }
        else {
            $results += New-Result -Name "TPM" -Status "Fail" -Details "TPM is not present."
        }
    }
    catch {
        try {
            $tpmWmi = Get-CimInstance -Namespace "root\cimv2\security\microsofttpm" -ClassName Win32_Tpm -ErrorAction Stop
            $enabled = $tpmWmi.IsEnabled().IsEnabled
            $activated = $tpmWmi.IsActivated().IsActivated
            $owned = $tpmWmi.IsOwned().IsOwned

            if ($enabled -and $activated) {
                $results += New-Result -Name "TPM" -Status "Pass" -Details "TPM is enabled and activated. Owned=$owned."
            }
            else {
                $results += New-Result -Name "TPM" -Status "Warning" -Details "TPM detected but may not be fully enabled/activated. Enabled=$enabled, Activated=$activated, Owned=$owned."
            }
        }
        catch {
            $results += New-Result -Name "TPM" -Status "Warning" -Details "Unable to query TPM status. Run as Administrator or confirm TPM is available to Windows."
        }
    }

    # Secure Boot
    try {
        $secureBoot = Confirm-SecureBootUEFI -ErrorAction Stop

        if ($secureBoot) {
            $results += New-Result -Name "Secure Boot" -Status "Pass" -Details "Secure Boot is enabled."
        }
        else {
           $results += New-Result -Name "Secure Boot" -Status "Warning" `
    -Details "Secure Boot is disabled (review if required by build standard)" `
    -Recommendation "Review BIOS/UEFI security policy for this client build."
        }
    }
    catch {
        try {
            $computerInfo = Get-ComputerInfo -Property BiosFirmwareType -ErrorAction Stop
            if ($computerInfo.BiosFirmwareType -eq "Legacy") {
                $results += New-Result -Name "Secure Boot" -Status "Warning" -Details "Device appears to be using Legacy BIOS, so Secure Boot is not available." -Recommendation "Consider rebuilding as UEFI/GPT if Secure Boot is required by the build standard."
            }
            else {
                $results += New-Result -Name "Secure Boot" -Status "Warning" -Details "Unable to confirm Secure Boot state." -Recommendation "Check BIOS/UEFI settings manually if Secure Boot is required."
            }
        }
        catch {
            $results += New-Result -Name "Secure Boot" -Status "Warning" -Details "Unable to confirm Secure Boot. Device may be legacy BIOS, virtualised, or permissions may be insufficient." -Recommendation "Check firmware type and Secure Boot configuration manually if required."
        }
    }

    # Windows activation
    try {
        $licensing = Get-CimInstance SoftwareLicensingProduct | Where-Object {
            $_.PartialProductKey -and $_.LicenseStatus -eq 1
        } | Select-Object -First 1

        if ($licensing) {
            $results += New-Result -Name "Windows Activation" -Status "Pass" -Details "Windows appears to be activated."
        }
        else {
            $results += New-Result -Name "Windows Activation" -Status "Warning" -Details "Windows activation could not be confirmed."
        }
    }
    catch {
        $results += New-Result -Name "Windows Activation" -Status "Warning" -Details "Unable to query activation status."
    }

   # Endpoint protection / AV detection
try {
    $registeredAv = @()

    try {
        $registeredAv = Get-CimInstance -Namespace "root\SecurityCenter2" -ClassName AntiVirusProduct -ErrorAction Stop
    }
    catch { }

    $registeredAvNames = @(
        $registeredAv |
        ForEach-Object { $_.displayName } |
        Where-Object { $_ }
    )

    $otherAv = @(
        $registeredAvNames |
        Where-Object { $_ -notmatch "Windows Defender|Microsoft Defender" }
    )

    # Third-party AV detected
    if ($otherAv.Count -gt 0) {
        $avName = $otherAv -join ', '

        $results += New-Result `
            -Name "Endpoint Protection" `
            -Status "Pass" `
            -Details "Endpoint protection detected: $avName." `
            -Recommendation "Confirm the security product is healthy and reporting correctly."
    }

    # Defender active
    else {
        try {
            $defender = Get-MpComputerStatus -ErrorAction Stop

            if ($defender.AMServiceEnabled -and $defender.RealTimeProtectionEnabled) {
                $results += New-Result `
                    -Name "Endpoint Protection" `
                    -Status "Pass" `
                    -Details "Microsoft Defender is active." `
                    -Recommendation "No action required."
            }
            elseif ($defender.AMServiceEnabled) {
                $results += New-Result `
                    -Name "Endpoint Protection" `
                    -Status "Warning" `
                    -Details "Microsoft Defender service is enabled but real-time protection may be off." `
                    -Recommendation "Check Defender policy or endpoint protection configuration."
            }
            else {
                $results += New-Result `
                    -Name "Endpoint Protection" `
                    -Status "Fail" `
                    -Details "No active endpoint protection could be confirmed." `
                    -Recommendation "Confirm endpoint protection is installed and active before handover."
            }
        }
        catch {
            $results += New-Result `
                -Name "Endpoint Protection" `
                -Status "Warning" `
                -Details "Unable to query endpoint protection status." `
                -Recommendation "Manually verify endpoint protection before handover."
        }
    }
}
catch {
    $results += New-Result `
        -Name "Endpoint Protection" `
        -Status "Warning" `
        -Details "Unable to query endpoint protection status." `
        -Recommendation "Manually verify endpoint protection before handover."
}

    # Network connectivity
    try {
        if (Test-Connection -ComputerName "8.8.8.8" -Count 1 -Quiet) {
            $results += New-Result -Name "Network Connectivity" -Status "Pass" -Details "Network connectivity test passed."
        }
        else {
            $results += New-Result -Name "Network Connectivity" -Status "Warning" -Details "Unable to ping external test address."
        }
    }
    catch {
        $results += New-Result -Name "Network Connectivity" -Status "Warning" -Details "Unable to test network connectivity."
    }

    # Domain / Entra join
    try {
        $computerSystem = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $domainJoined = [bool]$computerSystem.PartOfDomain
        $domainName = $computerSystem.Domain
        $azureAdJoined = $false
        $workplaceJoined = $false

        try {
            $dsregOutput = dsregcmd /status 2>$null
            $azureAdJoined = ($dsregOutput | Select-String -Pattern "AzureAdJoined *: *YES" -Quiet)
            $workplaceJoined = ($dsregOutput | Select-String -Pattern "WorkplaceJoined *: *YES" -Quiet)
        }
        catch { }

        if ($domainJoined -or $azureAdJoined) {
            $joinDetails = @()
            if ($domainJoined) { $joinDetails += "Domain joined: $domainName" }
            if ($azureAdJoined) { $joinDetails += "Entra joined: Yes" }
            if ($workplaceJoined) { $joinDetails += "Workplace joined: Yes" }
            $results += New-Result -Name "Domain / Entra Join" -Status "Pass" -Details ($joinDetails -join " | ")
        }
        elseif ($workplaceJoined) {
            $results += New-Result -Name "Domain / Entra Join" -Status "Warning" -Details "Device is workplace joined but not domain joined or Entra joined."
        }
        else {
            $results += New-Result -Name "Domain / Entra Join" -Status "Warning" -Details "Device does not appear to be domain joined or Entra joined."
        }
    }
    catch {
        $results += New-Result -Name "Domain / Entra Join" -Status "Warning" -Details "Unable to query domain or Entra join state."
    }

    # Windows Update service
    try {
        $wuService = Get-Service -Name wuauserv -ErrorAction Stop
        $wuCim = Get-CimInstance Win32_Service -Filter "Name='wuauserv'" -ErrorAction Stop
        $startMode = $wuCim.StartMode

        if ($startMode -eq "Disabled") {
            $results += New-Result -Name "Windows Update Service" -Status "Warning" -Details "Windows Update service is disabled." -Recommendation "Confirm update management policy. Re-enable Windows Update if this is not intentionally managed."
        }
        elseif ($wuService.Status -eq "Running") {
            $results += New-Result -Name "Windows Update Service" -Status "Pass" -Details "Windows Update service is running. Start mode: $startMode."
        }
        elseif ($wuService.Status -eq "Stopped" -and ($startMode -eq "Manual" -or $startMode -eq "Auto")) {
            $results += New-Result -Name "Windows Update Service" -Status "Pass" -Details "Windows Update service is stopped but available. Start mode: $startMode. This is normal on many modern Windows builds."
        }
        else {
            $results += New-Result -Name "Windows Update Service" -Status "Warning" -Details "Windows Update service status is $($wuService.Status). Start mode: $startMode." -Recommendation "Review Windows Update service configuration if updates are not applying correctly."
        }
    }
    catch {
        $results += New-Result -Name "Windows Update Service" -Status "Warning" -Details "Unable to query Windows Update service." -Recommendation "Manually verify Windows Update service state."
    }

    return $results
}

function Get-HealthSummary {
    param([array]$Results)

    if (-not $Results -or $Results.Count -eq 0) {
        return [PSCustomObject]@{
            Score   = 0
            Status  = "Not Run"
            Pass    = 0
            Warning = 0
            Fail    = 0
            Total   = 0
        }
    }

    $passCount = @($Results | Where-Object { $_.Status -eq "Pass" }).Count
    $warningCount = @($Results | Where-Object { $_.Status -eq "Warning" }).Count
    $failCount = @($Results | Where-Object { $_.Status -eq "Fail" }).Count
    $totalCount = $Results.Count

    $score = [math]::Round(((($passCount * 1) + ($warningCount * 0.5)) / $totalCount) * 100, 0)

    if ($failCount -gt 0) {
        $status = "Not Ready"
    }
    elseif ($warningCount -gt 0) {
        $status = "Ready With Warnings"
    }
    else {
        $status = "Ready"
    }

    [PSCustomObject]@{
        Score   = $score
        Status  = $status
        Pass    = $passCount
        Warning = $warningCount
        Fail    = $failCount
        Total   = $totalCount
    }
}

function Get-OverallStatus {
    param([array]$Results)
    return (Get-HealthSummary -Results $Results).Status
}

function Get-OverallStatusBrush {
    param([string]$Status)

    switch ($Status) {
        "Ready"               { "#107C10" }
        "Ready With Warnings" { "#B45309" }
        "Not Ready"           { "#D13438" }
        default                { "#6B7280" }
    }
}

function Get-ValidationSummaryText {
    param(
        [array]$AutomatedResults,
        [array]$ManualResults,
        [string]$TechnicianName
    )

    $summary = Get-HealthSummary -Results $AutomatedResults
    $generated = Get-Date -Format "dd MMM yyyy HH:mm:ss"

    # Make technician name look nicer
    if (-not [string]::IsNullOrWhiteSpace($TechnicianName)) {
        $TechnicianName = ($TechnicianName -replace '[._-]', ' ' | ForEach-Object {
            (Get-Culture).TextInfo.ToTitleCase($_.ToLower())
        })
    }

    # Automated issues
    $autoIssueLines = @()

    foreach ($result in $AutomatedResults | Where-Object { $_.Status -ne "Pass" }) {
        switch ($result.Name) {
            "Pending Reboot" {
                $autoIssueLines += "⚠ Pending Reboot – Restart device before handover"
            }
            "Secure Boot" {
                    $icon = if ($result.Status -eq "Fail") { "❌" } else { "⚠" }
                    $autoIssueLines += "$icon Secure Boot – Disabled (review if required by build standard)"
}
            "Endpoint Protection" {
                if ($result.Details -match "Endpoint protection detected: (.+?)\.?$") {
                    $avName = $matches[1]
                    $autoIssueLines += "⚠ Endpoint Protection – $avName detected"
                }
                else {
                    $autoIssueLines += "⚠ Endpoint Protection – Review security product status"
                }
            }
            default {
                $icon = if ($result.Status -eq "Fail") { "❌" } else { "⚠" }
                $autoIssueLines += "$icon $($result.Name) – $($result.Recommendation)"
            }
        }
    }

    if ($autoIssueLines.Count -eq 0) {
        $autoIssueLines = @("✅ No automated issues detected")
    }

    # Manual checks
    $manualOutstanding = @(
        $ManualResults |
        Where-Object { -not $_.Checked } |
        ForEach-Object { "⚠ $($_.Name)" }
    )

    $manualSection = ""
    if ($manualOutstanding.Count -gt 0) {
$manualSection = @"
Manual Checks Outstanding:
$($manualOutstanding -join "`r`n")
"@
    }

    @"
Endpoint Validation Summary

Device: $env:COMPUTERNAME
Technician: $TechnicianName
Generated: $generated

Overall Status: $(if ($summary.Status -eq 'Ready') { '✅' } elseif ($summary.Status -eq 'Ready With Warnings') { '⚠' } else { '❌' }) $($summary.Status)
Health Score: $($summary.Score)%

Checks:
✅ Pass: $($summary.Pass)
⚠ Warning: $($summary.Warning)
❌ Fail: $($summary.Fail)

Automated Issues / Actions:
$($autoIssueLines -join "`r`n")

$manualSection
"@
}

function Export-HtmlReport {
    param(
        [array]$AutomatedResults,
        [array]$ManualResults,
        [string]$TechnicianName,
        [string]$Notes
    )

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $safeDeviceName = $env:COMPUTERNAME -replace '[\\/:*?"<>|]', '_'
    $reportPath = Join-Path $ReportsPath "BuildValidation_${safeDeviceName}_$timestamp.html"

    $summary = Get-HealthSummary -Results $AutomatedResults
    $overall = $summary.Status
    $generated = Get-Date -Format "dd MMM yyyy HH:mm:ss"

    $autoRows = foreach ($result in $AutomatedResults) {
        $class = $result.Status.ToLower()
        "<tr><td>$($result.Name)</td><td class='$class'>$($result.Status)</td><td>$($result.Details)</td><td>$($result.Recommendation)</td></tr>"
    }

    $manualRows = foreach ($item in $ManualResults) {
        $status = if ($item.Checked) { "Pass" } else { "Not Confirmed" }
        $class = if ($item.Checked) { "pass" } else { "warning" }
        "<tr><td>$($item.Name)</td><td class='$class'>$status</td></tr>"
    }

    $encodedNotes = ConvertTo-HtmlSafe $Notes

    # Make technician name look nicer
    if (-not [string]::IsNullOrWhiteSpace($TechnicianName)) {
    $TechnicianName = ($TechnicianName -replace '[._-]', ' ' | ForEach-Object {
        (Get-Culture).TextInfo.ToTitleCase($_.ToLower())
    })
}

$encodedTechnician = ConvertTo-HtmlSafe $TechnicianName

    $html = @"
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<title>Device Build Validation Report</title>
<style>
    body {
        font-family: Segoe UI, Arial, sans-serif;
        background: #f5f7fa;
        color: #1f2937;
        margin: 0;
        padding: 24px;
    }
    .container {
        max-width: 1100px;
        margin: auto;
        background: white;
        border-radius: 12px;
        padding: 28px;
        box-shadow: 0 4px 18px rgba(0,0,0,0.08);
    }
    h1 {
        margin-top: 0;
        color: #111827;
    }
    h2 {
        border-bottom: 1px solid #e5e7eb;
        padding-bottom: 8px;
        margin-top: 32px;
    }
    .summary {
        display: grid;
        grid-template-columns: repeat(5, 1fr);
        gap: 12px;
        margin: 20px 0;
    }
    .status-banner {
        padding: 18px;
        border-radius: 12px;
        margin: 18px 0;
        color: white;
        background: #374151;
    }
    .status-ready { background: #107C10; }
    .status-warning { background: #B45309; }
    .status-fail { background: #D13438; }
    .status-title {
        font-size: 24px;
        font-weight: 700;
    }
    .status-subtitle {
        margin-top: 4px;
        opacity: .95;
    }
    .card {
        background: #f9fafb;
        border: 1px solid #e5e7eb;
        border-radius: 10px;
        padding: 14px;
    }
    .label {
        font-size: 12px;
        color: #6b7280;
        text-transform: uppercase;
        letter-spacing: .04em;
    }
    .value {
        font-size: 16px;
        font-weight: 600;
        margin-top: 4px;
    }
    table {
        width: 100%;
        border-collapse: collapse;
        margin-top: 12px;
    }
    th, td {
        border-bottom: 1px solid #e5e7eb;
        text-align: left;
        padding: 10px;
        vertical-align: top;
    }
    th {
        background: #f3f4f6;
    }
    .pass {
        color: #107c10;
        font-weight: 700;
    }
    .warning {
        color: #b45309;
        font-weight: 700;
    }
    .fail {
        color: #d13438;
        font-weight: 700;
    }
    .footer {
        margin-top: 32px;
        color: #6b7280;
        font-size: 12px;
    }
    pre {
        white-space: pre-wrap;
        background: #f9fafb;
        padding: 12px;
        border-radius: 8px;
        border: 1px solid #e5e7eb;
    }
</style>
</head>
<body>
<div class="container">
    <h1>Device Build Validation Report</h1>

    <div class="status-banner $(if ($overall -eq 'Ready') { 'status-ready' } elseif ($overall -eq 'Ready With Warnings') { 'status-warning' } else { 'status-fail' })">
        <div class="status-title">$overall - Health Score: $($summary.Score)%</div>
        <div class="status-subtitle">Pass: $($summary.Pass) | Warning: $($summary.Warning) | Fail: $($summary.Fail) | Total Checks: $($summary.Total)</div>
    </div>

    <div class="summary">
        <div class="card"><div class="label">Device</div><div class="value">$env:COMPUTERNAME</div></div>
        <div class="card"><div class="label">Generated</div><div class="value">$generated</div></div>
        <div class="card"><div class="label">Technician</div><div class="value">$encodedTechnician</div></div>
        <div class="card"><div class="label">Overall Status</div><div class="value">$overall</div></div>
        <div class="card"><div class="label">Health Score</div><div class="value">$($summary.Score)%</div></div>
    </div>

    <h2>Automated Checks</h2>
    <table>
        <tr><th>Check</th><th>Status</th><th>Details</th><th>Recommended Action</th></tr>
        $($autoRows -join "`n")
    </table>

    <h2>Manual Technician Checklist</h2>
    <table>
        <tr><th>Check</th><th>Status</th></tr>
        $($manualRows -join "`n")
    </table>

    <h2>Technician Notes</h2>
    <pre>$encodedNotes</pre>

    <div class="footer">
        Build Validator v1.0 • Developed by Michael Day
    </div>
</div>
</body>
</html>
"@

    $html | Set-Content -Path $reportPath -Encoding UTF8
    return $reportPath
}

# -----------------------------
# UI
# -----------------------------
$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Build Validator v1.0" Height="820" Width="1050" WindowStartupLocation="CenterScreen" Background="#F3F4F6">
    <Grid Margin="18">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto" />
            <RowDefinition Height="Auto" />
            <RowDefinition Height="*" />
            <RowDefinition Height="Auto" />
        </Grid.RowDefinitions>

        <Border Grid.Row="0" Background="#111827" CornerRadius="14" Padding="20" Margin="0,0,0,14">
            <StackPanel>
                <TextBlock Text="Build Validator" Foreground="White" FontSize="26" FontWeight="Bold" />
                <TextBlock Text="Post-build validation, technician checklist and HTML sign-off reporting" Foreground="#D1D5DB" FontSize="14" Margin="0,6,0,0" />
            </StackPanel>
        </Border>

        <Border Grid.Row="1" Background="White" CornerRadius="12" Padding="14" Margin="0,0,0,14">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="2*" />
                    <ColumnDefinition Width="2*" />
                    <ColumnDefinition Width="1*" />
                </Grid.ColumnDefinitions>

                <StackPanel Grid.Column="0">
                    <TextBlock Text="Device" FontWeight="Bold" />
                    <TextBlock x:Name="DeviceInfoText" Text="Loading..." Margin="0,5,0,0" />
                </StackPanel>

                <StackPanel Grid.Column="1">
                    <TextBlock Text="Technician Name" FontWeight="Bold" />
                    <TextBox x:Name="TechnicianNameBox" Height="28" Margin="0,5,20,0" />
                </StackPanel>

                <StackPanel Grid.Column="2">
                    <TextBlock Text="Overall Status" FontWeight="Bold" />
                    <TextBlock x:Name="OverallStatusText" Text="Not run" FontSize="18" FontWeight="Bold" Margin="0,5,0,0" Foreground="#6B7280" />
                    <TextBlock x:Name="HealthScoreText" Text="Health Score: 0%" FontSize="12" Margin="0,3,0,0" Foreground="#6B7280" />
                </StackPanel>
            </Grid>
        </Border>

        <Grid Grid.Row="2">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="1.25*" />
                <ColumnDefinition Width="1*" />
            </Grid.ColumnDefinitions>

            <Border Grid.Column="0" Background="White" CornerRadius="12" Padding="14" Margin="0,0,10,0">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto" />
                        <RowDefinition Height="*" />
                    </Grid.RowDefinitions>
                    <DockPanel Grid.Row="0" Margin="0,0,0,10">
                        <TextBlock Text="Automated Checks" FontSize="18" FontWeight="Bold" DockPanel.Dock="Left" />
                        <Button x:Name="RunChecksButton" Content="Run Checks" Width="130" Height="34" DockPanel.Dock="Right" />
                    </DockPanel>
                    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
                        <StackPanel x:Name="AutomatedResultsPanel" />
                    </ScrollViewer>
                </Grid>
            </Border>

            <Border Grid.Column="1" Background="White" CornerRadius="12" Padding="14" Margin="10,0,0,0">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto" />
                        <RowDefinition Height="Auto" />
                        <RowDefinition Height="*" />
                    </Grid.RowDefinitions>

<StackPanel Grid.Row="0" Margin="0,0,0,10">
    <TextBlock Text="Manual Technician Checklist"
               FontSize="18"
               FontWeight="Bold"
               Margin="0,0,0,8" />

    <StackPanel Orientation="Horizontal">
        <Button x:Name="SelectAllButton"
                Content="Select All"
                Width="80"
                Height="26"
                FontSize="11"
                Margin="0,0,8,0" />

        <Button x:Name="ClearChecksButton"
                Content="Clear"
                Width="60"
                Height="26"
                FontSize="11" />
    </StackPanel>
</StackPanel>

                    <StackPanel Grid.Row="1" x:Name="ManualChecklistPanel" Margin="0,0,0,14" />

                    <StackPanel Grid.Row="2">
                        <TextBlock Text="Technician Notes" FontWeight="Bold" Margin="0,0,0,6" />
                        <TextBox x:Name="NotesBox" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" Height="90" />
                    </StackPanel>
                </Grid>
            </Border>
        </Grid>

<Grid Grid.Row="3" Margin="0,14,0,0">
    <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*" />
        <ColumnDefinition Width="Auto" />
        <ColumnDefinition Width="Auto" />
    </Grid.ColumnDefinitions>

    <StackPanel Grid.Column="0">
        <TextBlock x:Name="StatusText"
                   Text="Ready."
                   Foreground="#374151"
                   TextTrimming="CharacterEllipsis" />

        <TextBlock Text="Build Validator v1.0 • Developed by Michael Day"
                   FontSize="11"
                   Foreground="#9CA3AF"
                   Margin="0,4,0,0"/>
    </StackPanel>

    <Button x:Name="CopySummaryButton"
            Grid.Column="1"
            Content="Copy Summary"
            Width="130"
            Height="36"
            Margin="0,0,10,0" />

    <Button x:Name="ExportButton"
            Grid.Column="2"
            Content="Export Report"
            Width="140"
            Height="36" />
</Grid>
    </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

# UI element references
$DeviceInfoText       = $window.FindName("DeviceInfoText")
$TechnicianNameBox    = $window.FindName("TechnicianNameBox")
$OverallStatusText    = $window.FindName("OverallStatusText")
$HealthScoreText      = $window.FindName("HealthScoreText")
$RunChecksButton      = $window.FindName("RunChecksButton")
$AutomatedResultsPanel = $window.FindName("AutomatedResultsPanel")
$ManualChecklistPanel = $window.FindName("ManualChecklistPanel")
$NotesBox             = $window.FindName("NotesBox")
$ExportButton         = $window.FindName("ExportButton")
$CopySummaryButton    = $window.FindName("CopySummaryButton")
$SelectAllButton      = $window.FindName("SelectAllButton")
$ClearChecksButton    = $window.FindName("ClearChecksButton")
$StatusText           = $window.FindName("StatusText")

# Populate device info
try {
    $os = Get-CimInstance Win32_OperatingSystem
    $DeviceInfoText.Text = "$env:COMPUTERNAME | $($os.Caption) | Build $($os.BuildNumber)"
}
catch {
    $DeviceInfoText.Text = "$env:COMPUTERNAME"
}

# Pre-populate technician name with the current Windows username if blank.
try {
    if ([string]::IsNullOrWhiteSpace($TechnicianNameBox.Text)) {
        $TechnicianNameBox.Text = $env:USERNAME
    }
}
catch { }

# Manual checklist items
$manualItems = @(
    "Asset label applied",
    "Charger included",
    "Physical condition checked",
    "Screen and keyboard tested",
    "Required applications checked",
    "User assigned / handover confirmed",
    "Device cleaned",
    "Accessories packed",
    "Dock / peripherals tested if required",
    "Ready for handover"
)

foreach ($item in $manualItems) {
    $checkbox = New-Object System.Windows.Controls.CheckBox
    $checkbox.Content = $item
    $checkbox.Margin = "0,3,0,3"
    $checkbox.FontSize = 13
    $ManualChecklistPanel.Children.Add($checkbox) | Out-Null
}

function Refresh-AutomatedResultsUI {
    $AutomatedResultsPanel.Children.Clear()

    foreach ($result in $script:AutomatedResults) {
        $border = New-Object System.Windows.Controls.Border
        $border.Margin = "0,0,0,8"
        $border.Padding = "10"
        $border.CornerRadius = "8"
        $border.BorderBrush = "#E5E7EB"
        $border.BorderThickness = "1"
        $border.Background = "#F9FAFB"

        $stack = New-Object System.Windows.Controls.StackPanel

        $title = New-Object System.Windows.Controls.TextBlock
        $title.Text = "$(Get-StatusIcon $result.Status) $($result.Name) - $($result.Status)"
        $title.FontWeight = "Bold"
        $title.Foreground = Get-StatusBrush $result.Status

        $details = New-Object System.Windows.Controls.TextBlock
        $details.Text = "$($result.Details)`nRecommended Action: $($result.Recommendation)"
        $details.TextWrapping = "Wrap"
        $details.Margin = "0,4,0,0"
        $details.Foreground = "#374151"

        $stack.Children.Add($title) | Out-Null
        $stack.Children.Add($details) | Out-Null
        $border.Child = $stack
        $AutomatedResultsPanel.Children.Add($border) | Out-Null
    }

    $summary = Get-HealthSummary -Results $script:AutomatedResults
    $overall = $summary.Status
    $OverallStatusText.Text = $overall
    $OverallStatusText.Foreground = Get-OverallStatusBrush $overall
    $HealthScoreText.Text = "Health Score: $($summary.Score)% | Pass: $($summary.Pass) | Warning: $($summary.Warning) | Fail: $($summary.Fail)"
}

$SelectAllButton.Add_Click({
    foreach ($child in $ManualChecklistPanel.Children) {
        if ($child -is [System.Windows.Controls.CheckBox]) {
            $child.IsChecked = $true
        }
    }
    $StatusText.Text = "All manual checks selected."
})

$ClearChecksButton.Add_Click({
    foreach ($child in $ManualChecklistPanel.Children) {
        if ($child -is [System.Windows.Controls.CheckBox]) {
            $child.IsChecked = $false
        }
    }
    $StatusText.Text = "Manual checks cleared."
})

$RunChecksButton.Add_Click({
    $StatusText.Text = "Running automated checks... please wait."
    $RunChecksButton.IsEnabled = $false
    $ExportButton.IsEnabled = $false
    $window.Cursor = "Wait"

    # Force the UI to update before the checks start.
    $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)

    try {
        $script:AutomatedResults = Run-AutomatedChecks
        Refresh-AutomatedResultsUI
        $StatusText.Text = "Checks complete."
    }
    catch {
        [System.Windows.MessageBox]::Show("An error occurred while running checks: $($_.Exception.Message)", "Error", "OK", "Error") | Out-Null
        $StatusText.Text = "Error running checks."
    }
    finally {
        $RunChecksButton.IsEnabled = $true
        $ExportButton.IsEnabled = $true
        $window.Cursor = $null
    }
})

$CopySummaryButton.Add_Click({
    if (-not $script:AutomatedResults -or $script:AutomatedResults.Count -eq 0) {
        [System.Windows.MessageBox]::Show("Please run automated checks before copying a summary.", "No Results", "OK", "Information") | Out-Null
        return
    }

    $manualResults = @()
    foreach ($child in $ManualChecklistPanel.Children) {
        if ($child -is [System.Windows.Controls.CheckBox]) {
            $manualResults += [PSCustomObject]@{
                Name    = [string]$child.Content
                Checked = [bool]$child.IsChecked
            }
        }
    }

    $summaryText = Get-ValidationSummaryText -AutomatedResults $script:AutomatedResults -ManualResults $manualResults -TechnicianName $TechnicianNameBox.Text
    [System.Windows.Clipboard]::SetText($summaryText)
    $StatusText.Text = "Validation summary copied to clipboard."
})

$ExportButton.Add_Click({
    if (-not $script:AutomatedResults -or $script:AutomatedResults.Count -eq 0) {
        [System.Windows.MessageBox]::Show("Please run automated checks before exporting a report.", "No Results", "OK", "Information") | Out-Null
        return
    }

    $manualResults = @()
    foreach ($child in $ManualChecklistPanel.Children) {
        if ($child -is [System.Windows.Controls.CheckBox]) {
            $manualResults += [PSCustomObject]@{
                Name    = [string]$child.Content
                Checked = [bool]$child.IsChecked
            }
        }
    }

    try {
        $report = Export-HtmlReport -AutomatedResults $script:AutomatedResults -ManualResults $manualResults -TechnicianName $TechnicianNameBox.Text -Notes $NotesBox.Text
        $StatusText.Text = "Report exported: $report"
        Start-Process $report
    }
    catch {
        [System.Windows.MessageBox]::Show("Failed to export report: $($_.Exception.Message)", "Export Error", "OK", "Error") | Out-Null
    }
})

# Show the window
$window.ShowDialog() | Out-Null
