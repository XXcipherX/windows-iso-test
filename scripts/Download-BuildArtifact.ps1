[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Url,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$DestinationPath,

    [string]$ArtifactName,

    [string]$GitHubToken
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function New-GitHubHeaders {
    $headers = @{
        Accept                 = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent'           = 'windows-iso-test'
    }

    if (-not [string]::IsNullOrWhiteSpace($GitHubToken)) {
        $headers.Authorization = "Bearer $GitHubToken"
    }

    return $headers
}

function Invoke-LargeFileDownload {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DownloadUrl,

        [hashtable]$Headers
    )

    $arguments = @(
        '--fail',
        '--location',
        '--retry', '3',
        '--retry-delay', '5',
        '--silent',
        '--show-error',
        '--output', $DestinationPath
    )

    if ($Headers -and $Headers.Authorization) {
        $arguments += @('--header', "Authorization: $($Headers.Authorization)")
        $arguments += @('--header', 'Accept: application/vnd.github+json')
        $arguments += @('--header', 'X-GitHub-Api-Version: 2022-11-28')
    }

    $arguments += $DownloadUrl
    & curl.exe @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Archive download failed with exit code $LASTEXITCODE."
    }
}

$destinationDirectory = Split-Path -Parent $DestinationPath
New-Item -ItemType Directory -Force -Path $destinationDirectory | Out-Null

$githubRunPattern = '^https://github\.com/(?<owner>[^/]+)/(?<repo>[^/]+)/actions/runs/(?<runId>\d+)(?:/artifacts/(?<artifactId>\d+))?'
$downloadUrl = $Url
$headers = $null

if ($Url -match $githubRunPattern) {
    if ([string]::IsNullOrWhiteSpace($GitHubToken)) {
        throw 'SOURCE_GITHUB_TOKEN is required for GitHub Actions run or artifact URLs.'
    }

    $owner = $Matches.owner
    $repository = $Matches.repo
    $runId = $Matches.runId
    $artifactId = $Matches.artifactId
    $headers = New-GitHubHeaders

    if ([string]::IsNullOrWhiteSpace($artifactId)) {
        $listUrl = "https://api.github.com/repos/$owner/$repository/actions/runs/$runId/artifacts?per_page=100"
        $response = Invoke-RestMethod -Uri $listUrl -Headers $headers
        $artifacts = @($response.artifacts | Where-Object { -not $_.expired })

        if (-not [string]::IsNullOrWhiteSpace($ArtifactName)) {
            $artifacts = @($artifacts | Where-Object { $_.name -eq $ArtifactName })
        }

        if ($artifacts.Count -eq 0) {
            throw 'No non-expired artifact matched the requested run and artifact name.'
        }
        if ($artifacts.Count -gt 1) {
            $availableNames = @($artifacts | Select-Object -ExpandProperty name) -join ', '
            throw "The run contains multiple artifacts. Set artifact_name to one of: $availableNames"
        }

        $artifactId = $artifacts[0].id
        Write-Host "Selected GitHub Actions artifact '$($artifacts[0].name)' (ID $artifactId)."
    }

    $downloadUrl = "https://api.github.com/repos/$owner/$repository/actions/artifacts/$artifactId/zip"
    Write-Host 'Downloading archive through the GitHub Actions artifact API.'
}
else {
    Write-Host 'Downloading archive from a direct URL.'
}

Invoke-LargeFileDownload -DownloadUrl $downloadUrl -Headers $headers

$archive = Get-Item -LiteralPath $DestinationPath
if ($archive.Length -le 0) {
    throw 'Downloaded archive is empty.'
}

Write-Host ("Archive downloaded: {0:N2} GiB" -f ($archive.Length / 1GB))
