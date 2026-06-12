[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$IsoPath,

    [ValidateRange(1, 100)]
    [int]$ImageIndex = 1,

    [string]$ExpectedSha256,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$WorkDirectory,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ReportDirectory,

    [switch]$RequireLowLatencyProfile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:Results = [System.Collections.Generic.List[object]]::new()
$script:FatalError = $null
$mountedIso = $false
$mountedWindowsImage = $false
$hiveLoaded = $false
$hiveName = "ISO_TEST_SYSTEM_$PID"
$mountDirectory = Join-Path $WorkDirectory 'mounted-image'
$exportedWimPath = Join-Path $WorkDirectory 'install-check.wim'
$resolvedIsoPath = $null

function Add-Result {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Scope,

        [Parameter(Mandatory = $true)]
        [string]$Check,

        [Parameter(Mandatory = $true)]
        [ValidateSet('PASS', 'WARN', 'FAIL', 'INFO')]
        [string]$Status,

        [Parameter(Mandatory = $true)]
        [string]$Details
    )

    $script:Results.Add([PSCustomObject]@{
        Scope   = $Scope
        Check   = $Check
        Status  = $Status
        Details = $Details
    })

    Write-Host "[$Status] [$Scope] $Check - $Details"
}

function Get-ChecksumFromFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    $content = Get-Content -LiteralPath $Path -Raw
    $match = [regex]::Match($content, '(?i)\b[0-9a-f]{64}\b')
    if ($match.Success) {
        return $match.Value.ToLowerInvariant()
    }

    return $null
}

function Test-FeatureOverride {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProviderRoot,

        [Parameter(Mandatory = $true)]
        [string]$ControlSet
    )

    $obfuscatedId = '1213986446'
    $definitionPath = "$ProviderRoot\$ControlSet\Control\FeatureManagement\Definitions\Associations\$obfuscatedId"
    $imageDefaultPath = "$ProviderRoot\$ControlSet\Control\FeatureManagement\Overrides\0\$obfuscatedId"
    $userOverridePath = "$ProviderRoot\$ControlSet\Control\FeatureManagement\Overrides\8\$obfuscatedId"

    if (-not (Test-Path -LiteralPath $definitionPath)) {
        $status = if ($RequireLowLatencyProfile) { 'FAIL' } else { 'WARN' }
        Add-Result $ControlSet 'Feature definition' $status "Feature 58989092 definition ($obfuscatedId) is absent."
        return $false
    }

    Add-Result $ControlSet 'Feature definition' 'PASS' "Feature 58989092 definition ($obfuscatedId) exists."

    $imageDefaultState = $null
    if (Test-Path -LiteralPath $imageDefaultPath) {
        try {
            $imageDefaultState = [int](
                Get-ItemProperty -LiteralPath $imageDefaultPath -Name EnabledState -ErrorAction Stop
            ).EnabledState
            Add-Result $ControlSet 'Image default' 'INFO' "EnabledState=$imageDefaultState."
        }
        catch {
            Add-Result $ControlSet 'Image default' 'WARN' "Could not read EnabledState: $_"
        }
    }
    else {
        Add-Result $ControlSet 'Image default' 'INFO' 'No ImageDefault (0) override exists.'
    }

    if ($imageDefaultState -eq 2) {
        Add-Result $ControlSet 'Low Latency Profile result' 'PASS' 'Feature is already enabled by ImageDefault (0); User (8) is not required.'
        return $true
    }

    if (-not (Test-Path -LiteralPath $userOverridePath)) {
        Add-Result $ControlSet 'User override' 'FAIL' 'User (8) override is required but absent.'
        return $false
    }

    $expectedValues = [ordered]@{
        EnabledState        = 2
        EnabledStateOptions = 0
        Variant             = 0
        VariantPayload      = 0
        VariantPayloadKind  = 0
    }

    $key = Get-Item -LiteralPath $userOverridePath
    $valid = $true

    foreach ($entry in $expectedValues.GetEnumerator()) {
        if ($key.GetValueNames() -notcontains $entry.Key) {
            Add-Result $ControlSet $entry.Key 'FAIL' 'Registry value is missing.'
            $valid = $false
            continue
        }

        $kind = $key.GetValueKind($entry.Key)
        $actualValue = [int]$key.GetValue($entry.Key)

        if ($kind -ne [Microsoft.Win32.RegistryValueKind]::DWord) {
            Add-Result $ControlSet $entry.Key 'FAIL' "Expected DWORD, got $kind."
            $valid = $false
        }
        elseif ($actualValue -ne $entry.Value) {
            Add-Result $ControlSet $entry.Key 'FAIL' "Expected $($entry.Value), got $actualValue."
            $valid = $false
        }
        else {
            Add-Result $ControlSet $entry.Key 'PASS' "DWORD value is $actualValue."
        }
    }

    if ($valid) {
        Add-Result $ControlSet 'Low Latency Profile result' 'PASS' 'User (8) override exactly matches feature 58989092.'
    }

    return $valid
}

function Write-Reports {
    New-Item -ItemType Directory -Force -Path $ReportDirectory | Out-Null

    $jsonPath = Join-Path $ReportDirectory 'iso-test-report.json'
    $markdownPath = Join-Path $ReportDirectory 'iso-test-report.md'
    $script:Results | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $jsonPath -Encoding utf8

    $passCount = @($script:Results | Where-Object Status -eq 'PASS').Count
    $warningCount = @($script:Results | Where-Object Status -eq 'WARN').Count
    $failureCount = @($script:Results | Where-Object Status -eq 'FAIL').Count
    $infoCount = @($script:Results | Where-Object Status -eq 'INFO').Count

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('## Windows ISO Offline Test')
    $lines.Add('')
    $lines.Add("| Result | Count |")
    $lines.Add("| :--- | ---: |")
    $lines.Add("| PASS | $passCount |")
    $lines.Add("| WARN | $warningCount |")
    $lines.Add("| FAIL | $failureCount |")
    $lines.Add("| INFO | $infoCount |")
    $lines.Add('')
    $lines.Add('| Scope | Check | Status | Details |')
    $lines.Add('| :--- | :--- | :---: | :--- |')

    foreach ($result in $script:Results) {
        $details = "$($result.Details)" -replace '\|', '\|' -replace '\r?\n', ' '
        $lines.Add("| $($result.Scope) | $($result.Check) | $($result.Status) | $details |")
    }

    $lines | Set-Content -LiteralPath $markdownPath -Encoding utf8

    if ($env:GITHUB_STEP_SUMMARY) {
        Get-Content -LiteralPath $markdownPath | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY
    }

    return $failureCount
}

try {
    New-Item -ItemType Directory -Force -Path $WorkDirectory | Out-Null
    New-Item -ItemType Directory -Force -Path $mountDirectory | Out-Null

    $resolvedIsoPath = (Resolve-Path -LiteralPath $IsoPath).Path
    $isoItem = Get-Item -LiteralPath $resolvedIsoPath
    Add-Result 'ISO' 'File' 'PASS' "$($isoItem.Name), $([math]::Round($isoItem.Length / 1GB, 2)) GiB."

    $actualSha256 = (Get-FileHash -LiteralPath $resolvedIsoPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $checksumToVerify = if ([string]::IsNullOrWhiteSpace($ExpectedSha256)) {
        $checksumCandidates = @(
            "$resolvedIsoPath.sha256",
            "$resolvedIsoPath.sha256.txt"
        )

        $checksumCandidates += @(
            Get-ChildItem -LiteralPath $isoItem.DirectoryName -Filter '*.sha256' -File -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty FullName
        )

        $checksumCandidates |
            Select-Object -Unique |
            ForEach-Object { Get-ChecksumFromFile $_ } |
            Where-Object { $_ } |
            Select-Object -First 1
    }
    else {
        $ExpectedSha256.Trim().ToLowerInvariant()
    }

    if ($checksumToVerify) {
        if ($actualSha256 -ne $checksumToVerify) {
            Add-Result 'ISO' 'SHA256' 'FAIL' "Expected $checksumToVerify, got $actualSha256."
        }
        else {
            Add-Result 'ISO' 'SHA256' 'PASS' $actualSha256
        }
    }
    else {
        Add-Result 'ISO' 'SHA256' 'WARN' "No expected checksum was supplied or found. Calculated: $actualSha256"
    }

    $diskImage = Mount-DiskImage -ImagePath $resolvedIsoPath -Access ReadOnly -PassThru
    $mountedIso = $true

    $isoDrive = $null
    for ($attempt = 1; $attempt -le 20 -and -not $isoDrive; $attempt++) {
        $isoDrive = $diskImage |
            Get-Volume -ErrorAction SilentlyContinue |
            Where-Object DriveLetter |
            Select-Object -First 1 -ExpandProperty DriveLetter

        if (-not $isoDrive) {
            Start-Sleep -Milliseconds 500
        }
    }

    if (-not $isoDrive) {
        throw 'Mounted ISO did not receive a drive letter.'
    }

    $isoRoot = "${isoDrive}:"
    Add-Result 'ISO' 'Mount' 'PASS' "Mounted read-only at $isoRoot."

    $wimPath = Join-Path $isoRoot 'sources\install.wim'
    $esdPath = Join-Path $isoRoot 'sources\install.esd'

    if (Test-Path -LiteralPath $wimPath) {
        $sourceImagePath = $wimPath
        $mountImagePath = $wimPath
        $mountImageIndex = $ImageIndex
        Add-Result 'Image' 'Format' 'PASS' 'Found install.wim.'
    }
    elseif (Test-Path -LiteralPath $esdPath) {
        $sourceImagePath = $esdPath
        Add-Result 'Image' 'Format' 'PASS' 'Found install.esd.'
    }
    else {
        throw 'Neither sources\install.wim nor sources\install.esd exists in the ISO.'
    }

    $images = @(Get-WindowsImage -ImagePath $sourceImagePath)
    $selectedImage = $images | Where-Object ImageIndex -eq $ImageIndex | Select-Object -First 1
    if (-not $selectedImage) {
        $availableIndexes = @($images | Select-Object -ExpandProperty ImageIndex) -join ', '
        throw "Image index ${ImageIndex} does not exist. Available indexes: $availableIndexes"
    }

    Add-Result 'Image' 'Selection' 'PASS' "Index ${ImageIndex}: $($selectedImage.ImageName), architecture $($selectedImage.Architecture)."

    if ($sourceImagePath -eq $esdPath) {
        Add-Result 'Image' 'ESD export' 'INFO' 'Exporting the selected ESD image to a temporary WIM for read-only inspection.'
        Export-WindowsImage `
            -SourceImagePath $esdPath `
            -SourceIndex $ImageIndex `
            -DestinationImagePath $exportedWimPath `
            -CompressionType Fast `
            -CheckIntegrity | Out-Null
        $mountImagePath = $exportedWimPath
        $mountImageIndex = 1
        Add-Result 'Image' 'ESD export' 'PASS' 'Temporary WIM export completed.'
    }

    Mount-WindowsImage `
        -ImagePath $mountImagePath `
        -Index $mountImageIndex `
        -Path $mountDirectory `
        -ReadOnly `
        -CheckIntegrity | Out-Null
    $mountedWindowsImage = $true
    Add-Result 'Image' 'Mount' 'PASS' 'Windows image mounted read-only.'

    $systemHivePath = Join-Path $mountDirectory 'Windows\System32\config\SYSTEM'
    if (-not (Test-Path -LiteralPath $systemHivePath -PathType Leaf)) {
        throw "Offline SYSTEM hive not found at $systemHivePath."
    }

    $loadOutput = (& reg.exe load "HKLM\$hiveName" $systemHivePath 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "Could not load offline SYSTEM hive. Output: $loadOutput"
    }
    $hiveLoaded = $true
    Add-Result 'Registry' 'SYSTEM hive' 'PASS' "Loaded as HKLM\$hiveName."

    $providerRoot = "Registry::HKEY_LOCAL_MACHINE\$hiveName"
    $select = Get-ItemProperty -LiteralPath "$providerRoot\Select"
    $currentControlSet = 'ControlSet{0:D3}' -f [int]$select.Current

    Add-Result 'Registry' 'Select' 'PASS' "Current=$($select.Current), Default=$($select.Default), LastKnownGood=$($select.LastKnownGood), resolved current=$currentControlSet."

    $controlSets = @(
        Get-Item "$providerRoot\ControlSet*" -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -match '^ControlSet\d{3}$' } |
            Select-Object -ExpandProperty PSChildName |
            Sort-Object
    )

    if ($controlSets.Count -eq 0) {
        throw 'No ControlSetXXX keys exist in the offline SYSTEM hive.'
    }

    Add-Result 'Registry' 'Control sets' 'PASS' ($controlSets -join ', ')

    if ($currentControlSet -notin $controlSets) {
        Add-Result 'Registry' 'Active control set' 'FAIL' "$currentControlSet is referenced by Select\Current but does not exist."
    }
    else {
        Add-Result 'Registry' 'Active control set' 'PASS' "$currentControlSet exists."
    }

    foreach ($controlSet in $controlSets) {
        [void](Test-FeatureOverride -ProviderRoot $providerRoot -ControlSet $controlSet)
    }
}
catch {
    $script:FatalError = $_
    Add-Result 'Test' 'Fatal error' 'FAIL' "$_"
}
finally {
    if ($hiveLoaded) {
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()

        $unloaded = $false
        for ($attempt = 1; $attempt -le 3 -and -not $unloaded; $attempt++) {
            & reg.exe unload "HKLM\$hiveName" *> $null
            if ($LASTEXITCODE -eq 0) {
                $unloaded = $true
            }
            elseif ($attempt -lt 3) {
                Start-Sleep -Seconds 2
            }
        }

        if ($unloaded) {
            Add-Result 'Cleanup' 'SYSTEM hive' 'PASS' 'Offline hive unloaded.'
        }
        else {
            Add-Result 'Cleanup' 'SYSTEM hive' 'FAIL' 'Offline hive could not be unloaded.'
        }
    }

    if (-not $mountedWindowsImage) {
        $mountedWindowsImage = [bool](
            Get-WindowsImage -Mounted -ErrorAction SilentlyContinue |
                Where-Object { $_.Path -and $_.Path -ieq $mountDirectory }
        )
    }

    if ($mountedWindowsImage) {
        try {
            Dismount-WindowsImage -Path $mountDirectory -Discard | Out-Null
            Add-Result 'Cleanup' 'Windows image' 'PASS' 'Image dismounted.'
        }
        catch {
            Add-Result 'Cleanup' 'Windows image' 'FAIL' "Dismount failed: $_"
        }
    }

    if ($mountedIso -and $resolvedIsoPath) {
        try {
            Dismount-DiskImage -ImagePath $resolvedIsoPath | Out-Null
            Add-Result 'Cleanup' 'ISO' 'PASS' 'ISO dismounted.'
        }
        catch {
            Add-Result 'Cleanup' 'ISO' 'FAIL' "Dismount failed: $_"
        }
    }
}

$failureCount = Write-Reports
if ($failureCount -gt 0) {
    throw "Windows ISO offline test failed with $failureCount failed check(s)."
}

Write-Host 'Windows ISO offline test completed successfully.'
