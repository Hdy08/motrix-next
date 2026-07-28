#Requires -Version 5.1

<#
.SYNOPSIS
Builds a uniquely named Windows installer and removes generated build output.

.DESCRIPTION
The default Package action verifies the repository, runs the required frontend
and Rust checks, builds frontend assets outside the protected dist directory,
creates an unsigned NSIS installer, verifies embedded frontend assets and
SHA-256, updates the single pending CHANGELOG package slot, removes fixed
allowlisted temporary directories, and leaves only installers in dist.

.EXAMPLE
.\package-and-clean.ps1

.EXAMPLE
.\package-and-clean.ps1 -Action CleanOnly
#>

[CmdletBinding()]
param(
  [ValidateSet('Package', 'CleanOnly')]
  [string] $Action = 'Package',

  [ValidateSet('x64', 'arm64')]
  [string] $Architecture = 'x64',

  [switch] $KeepTemporaryOnFailure
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Get-NormalizedPath {
  param([Parameter(Mandatory)][string] $Path)

  return [System.IO.Path]::GetFullPath($Path).TrimEnd([char[]]@('\', '/'))
}

function ConvertFrom-CodePoints {
  param([Parameter(Mandatory)][int[]] $CodePoints)

  return -join ($CodePoints | ForEach-Object { [char] $_ })
}

$script:RepoRoot = Get-NormalizedPath -Path $PSScriptRoot
$script:TauriRoot = Join-Path $script:RepoRoot 'src-tauri'
$script:TargetDirectory = Get-NormalizedPath -Path (Join-Path $script:TauriRoot 'target')
$script:CoverageDirectory = Get-NormalizedPath -Path (Join-Path $script:RepoRoot 'coverage')
$script:DistSsrDirectory = Get-NormalizedPath -Path (Join-Path $script:RepoRoot 'dist-ssr')
$script:DistDirectory = Get-NormalizedPath -Path (Join-Path $script:RepoRoot 'dist')
$script:ChangelogPath = Join-Path $script:RepoRoot 'CHANGELOG.md'
$script:PackageJsonPath = Join-Path $script:RepoRoot 'package.json'
$script:CargoManifestPath = Join-Path $script:TauriRoot 'Cargo.toml'
$script:TauriConfigPath = Join-Path $script:TauriRoot 'tauri.conf.json'
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:InstallerLabel = ConvertFrom-CodePoints -CodePoints @(0x5B89, 0x88C5, 0x5305)
$script:PendingLabel = ConvertFrom-CodePoints -CodePoints @(0x5F85, 0x751F, 0x6210)
$script:BuildCommitLabel = ConvertFrom-CodePoints -CodePoints @(0x6784, 0x5EFA, 0x63D0, 0x4EA4)
$script:FullWidthColon = [char] 0xFF1A

$script:AllowedCleanupDirectories = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
[void] $script:AllowedCleanupDirectories.Add($script:TargetDirectory)
[void] $script:AllowedCleanupDirectories.Add($script:CoverageDirectory)
[void] $script:AllowedCleanupDirectories.Add($script:DistSsrDirectory)

$script:PnpmExecutable = $null
$script:PnpmPrefix = @()

function Write-Step {
  param([Parameter(Mandatory)][string] $Message)

  Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Resolve-Executable {
  param([Parameter(Mandatory)][string] $Name)

  $candidates = @("$Name.cmd", "$Name.exe", $Name)
  foreach ($candidate in $candidates) {
    $command = Get-Command $candidate -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) {
      return $command.Source
    }
  }

  throw "Required executable '$Name' was not found in PATH."
}

function Invoke-NativeCommand {
  param(
    [Parameter(Mandatory)][string] $FilePath,
    [Parameter()][string[]] $ArgumentList = @(),
    [Parameter(Mandatory)][string] $Description,
    [Parameter()][string] $WorkingDirectory = $script:RepoRoot
  )

  Write-Step -Message $Description
  Push-Location -LiteralPath $WorkingDirectory
  $previousErrorActionPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    & $FilePath @ArgumentList
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorActionPreference
    Pop-Location
  }

  if ($exitCode -ne 0) {
    throw "$Description failed with exit code $exitCode."
  }
}

function Get-NativeOutput {
  param(
    [Parameter(Mandatory)][string] $FilePath,
    [Parameter()][string[]] $ArgumentList = @(),
    [Parameter(Mandatory)][string] $Description,
    [Parameter()][int[]] $SuccessExitCodes = @(0),
    [Parameter()][string] $WorkingDirectory = $script:RepoRoot
  )

  $stdoutPath = [System.IO.Path]::GetTempFileName()
  $stderrPath = [System.IO.Path]::GetTempFileName()
  $stdout = ''
  $stderr = ''

  Push-Location -LiteralPath $WorkingDirectory
  $previousErrorActionPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    & $FilePath @ArgumentList 1> $stdoutPath 2> $stderrPath
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorActionPreference
    Pop-Location
    $stdout = [System.IO.File]::ReadAllText($stdoutPath)
    $stderr = [System.IO.File]::ReadAllText($stderrPath)
    [System.IO.File]::Delete($stdoutPath)
    [System.IO.File]::Delete($stderrPath)
  }

  if ($SuccessExitCodes -notcontains $exitCode) {
    $details = @($stdout.Trim(), $stderr.Trim()) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $renderedOutput = $details -join [Environment]::NewLine
    throw "$Description failed with exit code $exitCode.$([Environment]::NewLine)$renderedOutput"
  }
  if (-not [string]::IsNullOrWhiteSpace($stderr)) {
    Write-Warning "$Description wrote to stderr: $($stderr.Trim())"
  }

  return $stdout.TrimEnd([char[]]@([char] 13, [char] 10))
}

function Initialize-Pnpm {
  param(
    [Parameter(Mandatory)][string] $PackageManagerSpec,
    [Parameter(Mandatory)][string] $ExpectedVersion
  )

  $pnpmCommand = Get-Command 'pnpm.cmd' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -eq $pnpmCommand) {
    $pnpmCommand = Get-Command 'pnpm' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  }

  if ($null -ne $pnpmCommand) {
    $actualVersion = Get-NativeOutput -FilePath $pnpmCommand.Source -ArgumentList @('--version') -Description 'Checking pnpm version'
    if ($actualVersion -eq $ExpectedVersion) {
      $script:PnpmExecutable = $pnpmCommand.Source
      $script:PnpmPrefix = @()
      return
    }

    Write-Warning "Ignoring pnpm $actualVersion because package.json pins $ExpectedVersion."
  }

  $script:PnpmExecutable = Resolve-Executable -Name 'npx'
  $script:PnpmPrefix = @('--yes', $PackageManagerSpec)

  $resolvedVersion = Get-NativeOutput `
    -FilePath $script:PnpmExecutable `
    -ArgumentList ($script:PnpmPrefix + @('--version')) `
    -Description 'Resolving pinned pnpm version'
  if ($resolvedVersion -ne $ExpectedVersion) {
    throw "Pinned pnpm resolution returned '$resolvedVersion' instead of '$ExpectedVersion'."
  }
}

function Invoke-Pnpm {
  param(
    [Parameter()][string[]] $PnpmArguments = @(),
    [Parameter(Mandatory)][string] $Description
  )

  Invoke-NativeCommand `
    -FilePath $script:PnpmExecutable `
    -ArgumentList ($script:PnpmPrefix + $PnpmArguments) `
    -Description $Description
}

function Assert-RegularDirectoryWithoutReparsePoint {
  param([Parameter(Mandatory)][string] $Path)

  $rootItem = Get-Item -LiteralPath $Path -Force
  if (-not $rootItem.PSIsContainer) {
    throw "Expected a directory but found a file: $Path"
  }
  if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Refusing to operate on reparse-point directory: $Path"
  }
}

function Assert-DirectoryHasNoReparsePoints {
  param([Parameter(Mandatory)][string] $Path)

  if (-not (Test-Path -LiteralPath $Path)) {
    return
  }

  Assert-RegularDirectoryWithoutReparsePoint -Path $Path

  $reparsePoint = Get-ChildItem -LiteralPath $Path -Force -Recurse -ErrorAction Stop |
    Where-Object { ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 } |
    Select-Object -First 1
  if ($null -ne $reparsePoint) {
    throw "Refusing to operate on a directory containing a reparse point: $($reparsePoint.FullName)"
  }
}

function Assert-PathComponentsAreNotReparsePoints {
  param([Parameter(Mandatory)][string] $Path)

  $normalizedPath = Get-NormalizedPath -Path $Path
  $pathRoot = [System.IO.Path]::GetPathRoot($normalizedPath)
  $relativePath = $normalizedPath.Substring($pathRoot.Length)
  $currentPath = $pathRoot

  foreach ($segment in $relativePath -split '[\\/]') {
    if ([string]::IsNullOrWhiteSpace($segment)) {
      continue
    }

    $currentPath = Join-Path $currentPath $segment
    if (-not (Test-Path -LiteralPath $currentPath)) {
      break
    }

    $item = Get-Item -LiteralPath $currentPath -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "Refusing to operate through reparse-point path component: $currentPath"
    }
  }
}

function Assert-RegularFileWithoutReparsePoint {
  param([Parameter(Mandatory)][string] $Path)

  $item = Get-Item -LiteralPath $Path -Force
  if ($item.PSIsContainer -or ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Expected a regular file without a reparse point: $Path"
  }
}

function Remove-SafeDirectory {
  param([Parameter(Mandatory)][string] $Path)

  $normalizedPath = Get-NormalizedPath -Path $Path
  if (-not $script:AllowedCleanupDirectories.Contains($normalizedPath)) {
    throw "Cleanup path is not in the fixed allowlist: $normalizedPath"
  }
  if ($normalizedPath -eq $script:RepoRoot) {
    throw 'Refusing to remove the repository root.'
  }
  $repoPrefix = $script:RepoRoot + [System.IO.Path]::DirectorySeparatorChar
  if (-not $normalizedPath.StartsWith($repoPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Cleanup path is outside the repository: $normalizedPath"
  }

  Assert-PathComponentsAreNotReparsePoints -Path $normalizedPath
  if (-not (Test-Path -LiteralPath $normalizedPath)) {
    return
  }

  Assert-DirectoryHasNoReparsePoints -Path $normalizedPath

  $lastError = $null
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    try {
      Remove-Item -LiteralPath $normalizedPath -Recurse -Force -ErrorAction Stop
      $lastError = $null
      break
    } catch {
      $lastError = $_
      if ($attempt -lt 3) {
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
        Start-Sleep -Seconds 2
      }
    }
  }

  if ($null -ne $lastError) {
    throw "Failed to remove '$normalizedPath' after 3 attempts: $($lastError.Exception.Message)"
  }
  if (Test-Path -LiteralPath $normalizedPath) {
    throw "Cleanup verification failed; path still exists: $normalizedPath"
  }

  Write-Host "Removed temporary directory: $normalizedPath"
}

function Invoke-GeneratedCleanup {
  $cleanupErrors = New-Object System.Collections.Generic.List[string]
  foreach ($directory in @($script:TargetDirectory, $script:CoverageDirectory, $script:DistSsrDirectory)) {
    try {
      Remove-SafeDirectory -Path $directory
    } catch {
      $cleanupErrors.Add($_.Exception.Message)
    }
  }

  try {
    Remove-NonInstallerDistContent
  } catch {
    $cleanupErrors.Add($_.Exception.Message)
  }

  if ($cleanupErrors.Count -gt 0) {
    throw "Cleanup failed:$([Environment]::NewLine)- $($cleanupErrors -join "$([Environment]::NewLine)- ")"
  }
}

function Ensure-DistDirectory {
  Assert-PathComponentsAreNotReparsePoints -Path $script:DistDirectory
  if (Test-Path -LiteralPath $script:DistDirectory) {
    Assert-RegularDirectoryWithoutReparsePoint -Path $script:DistDirectory
    return
  }

  [void] [System.IO.Directory]::CreateDirectory($script:DistDirectory)
  Assert-RegularDirectoryWithoutReparsePoint -Path $script:DistDirectory
}

function Test-IsDistInstaller {
  param([Parameter(Mandatory)][System.IO.FileSystemInfo] $Item)

  return -not $Item.PSIsContainer -and $Item.Extension -ieq '.exe'
}

function Get-ValidatedRepositoryIdentity {
  param(
    [Parameter(Mandatory)][string] $GitExecutable,
    [Parameter()][string] $ExpectedCommit,
    [Parameter()][string] $ExpectedShortCommit
  )

  $branch = Get-NativeOutput -FilePath $GitExecutable -ArgumentList @('branch', '--show-current') -Description 'Reading current branch'
  if ($branch -ne 'main') {
    throw "Packaging is only allowed from main; current branch is '$branch'."
  }

  $originUrl = Get-NativeOutput -FilePath $GitExecutable -ArgumentList @('remote', 'get-url', 'origin') -Description 'Reading origin URL'
  $allowedOriginPattern = '(?i)^(?:https://github\.com/Hdy08/motrix-next(?:\.git)?/?|git@github\.com:Hdy08/motrix-next(?:\.git)?|ssh://git@github\.com/Hdy08/motrix-next(?:\.git)?/?)$'
  if ($originUrl -notmatch $allowedOriginPattern) {
    throw "origin must point to Hdy08/motrix-next; found '$originUrl'."
  }

  $status = Get-NativeOutput -FilePath $GitExecutable -ArgumentList @('status', '--porcelain=v1', '--untracked-files=all') -Description 'Checking worktree cleanliness'
  if (-not [string]::IsNullOrWhiteSpace($status)) {
    throw "The worktree must be clean so the package matches HEAD:$([Environment]::NewLine)$status"
  }

  $currentCommit = Get-NativeOutput -FilePath $GitExecutable -ArgumentList @('rev-parse', '--verify', 'HEAD') -Description 'Reading current commit'
  $shortCommit = Get-NativeOutput -FilePath $GitExecutable -ArgumentList @('rev-parse', '--short=7', 'HEAD') -Description 'Reading short commit'
  if ($shortCommit -notmatch '^[0-9a-f]{7,40}$') {
    throw "Unexpected Git short hash '$shortCommit'."
  }
  if (-not [string]::IsNullOrWhiteSpace($ExpectedCommit) -and $currentCommit -ne $ExpectedCommit) {
    throw "HEAD changed during packaging: expected '$ExpectedCommit', found '$currentCommit'."
  }
  if (-not [string]::IsNullOrWhiteSpace($ExpectedShortCommit) -and $shortCommit -ne $ExpectedShortCommit) {
    throw "The short HEAD hash changed during packaging: expected '$ExpectedShortCommit', found '$shortCommit'."
  }

  return [pscustomobject]@{
    Commit = $currentCommit
    ShortCommit = $shortCommit
  }
}

function Get-InstallerSnapshot {
  Ensure-DistDirectory

  $snapshot = @{}
  foreach ($file in Get-ChildItem -LiteralPath $script:DistDirectory -File -Force) {
    if (-not (Test-IsDistInstaller -Item $file)) {
      continue
    }

    Assert-RegularFileWithoutReparsePoint -Path $file.FullName
    $snapshot[$file.Name] = [pscustomobject]@{
      Length = $file.Length
      Hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
  }

  return $snapshot
}

function Assert-InstallerSnapshotPreserved {
  param(
    [Parameter(Mandatory)][hashtable] $Before,
    [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $ExpectedNewFiles
  )

  $after = Get-InstallerSnapshot
  foreach ($installerName in $Before.Keys) {
    if (-not $after.ContainsKey($installerName)) {
      throw "An existing installer was removed: $installerName"
    }

    $beforeEntry = $Before[$installerName]
    $afterEntry = $after[$installerName]
    if ($beforeEntry.Length -ne $afterEntry.Length -or $beforeEntry.Hash -ne $afterEntry.Hash) {
      throw "An existing installer was modified: $installerName"
    }
  }

  $expected = @{}
  foreach ($installerName in $ExpectedNewFiles) {
    $expected[$installerName] = $true
  }

  $unexpected = @($after.Keys | Where-Object { -not $Before.ContainsKey($_) -and -not $expected.ContainsKey($_) })
  if ($unexpected.Count -gt 0) {
    throw "Unexpected installers were added to dist: $($unexpected -join ', ')"
  }
  foreach ($installerName in $ExpectedNewFiles) {
    if (-not $after.ContainsKey($installerName)) {
      throw "Expected package output is missing from dist: $installerName"
    }
  }
}

function Assert-DistContainsInstallersOnly {
  Ensure-DistDirectory

  $unexpectedItems = New-Object System.Collections.Generic.List[string]
  foreach ($item in Get-ChildItem -LiteralPath $script:DistDirectory -Force) {
    if (Test-IsDistInstaller -Item $item) {
      Assert-RegularFileWithoutReparsePoint -Path $item.FullName
      continue
    }

    $unexpectedItems.Add($item.Name)
  }

  if ($unexpectedItems.Count -gt 0) {
    throw "dist must contain root-level .exe installers only; found: $($unexpectedItems -join ', ')"
  }
}

function Assert-SafeDistCleanupItem {
  param([Parameter(Mandatory)][System.IO.FileSystemInfo] $Item)

  if (Test-IsDistInstaller -Item $Item) {
    throw "Refusing to remove an installer from dist: $($Item.FullName)"
  }
  if (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Refusing to remove a reparse point from dist: $($Item.FullName)"
  }
  if (-not $Item.PSIsContainer) {
    Assert-RegularFileWithoutReparsePoint -Path $Item.FullName
    return
  }

  Assert-DirectoryHasNoReparsePoints -Path $Item.FullName
  $nestedExecutable = Get-ChildItem -LiteralPath $Item.FullName -File -Force -Recurse |
    Where-Object { $_.Extension -ieq '.exe' } |
    Select-Object -First 1
  if ($null -ne $nestedExecutable) {
    throw "Refusing to remove a dist directory containing a possible installer: $($nestedExecutable.FullName)"
  }
}

function Remove-NonInstallerDistContent {
  Ensure-DistDirectory
  $installerSnapshot = Get-InstallerSnapshot
  $itemsToRemove = New-Object 'System.Collections.Generic.List[System.IO.FileSystemInfo]'
  $cleanupErrors = New-Object System.Collections.Generic.List[string]

  foreach ($item in @(Get-ChildItem -LiteralPath $script:DistDirectory -Force)) {
    if (Test-IsDistInstaller -Item $item) {
      continue
    }

    try {
      Assert-SafeDistCleanupItem -Item $item
      [void] $itemsToRemove.Add($item)
    } catch {
      $cleanupErrors.Add($_.Exception.Message)
    }
  }

  if ($cleanupErrors.Count -eq 0) {
    foreach ($item in $itemsToRemove) {
      try {
        $currentItem = Get-Item -LiteralPath $item.FullName -Force
        Assert-SafeDistCleanupItem -Item $currentItem
        if ($currentItem.PSIsContainer) {
          Remove-Item -LiteralPath $currentItem.FullName -Recurse -Force -ErrorAction Stop
        } else {
          Remove-Item -LiteralPath $currentItem.FullName -Force -ErrorAction Stop
        }
        if (Test-Path -LiteralPath $currentItem.FullName) {
          throw "dist cleanup verification failed; path still exists: $($currentItem.FullName)"
        }

        Write-Host "Removed non-installer dist content: $($currentItem.FullName)"
      } catch {
        $cleanupErrors.Add($_.Exception.Message)
      }
    }
  }

  try {
    Assert-InstallerSnapshotPreserved -Before $installerSnapshot -ExpectedNewFiles @()
  } catch {
    $cleanupErrors.Add($_.Exception.Message)
  }
  try {
    Assert-DistContainsInstallersOnly
  } catch {
    $cleanupErrors.Add($_.Exception.Message)
  }

  if ($cleanupErrors.Count -gt 0) {
    throw "Failed to clean non-installer dist content:$([Environment]::NewLine)- $($cleanupErrors -join "$([Environment]::NewLine)- ")"
  }
}

function Get-PendingPackageSlot {
  param(
    [Parameter(Mandatory)][string] $GitExecutable,
    [Parameter(Mandatory)][string] $CurrentCommit
  )

  if (-not (Test-Path -LiteralPath $script:ChangelogPath -PathType Leaf)) {
    throw 'CHANGELOG.md is required before packaging.'
  }
  Assert-RegularFileWithoutReparsePoint -Path $script:ChangelogPath

  $content = [System.IO.File]::ReadAllText($script:ChangelogPath)
  $installerPendingLine = "- $($script:InstallerLabel)$($script:FullWidthColon)$($script:PendingLabel)"
  $checksumPendingLine = "- SHA-256$($script:FullWidthColon)$($script:PendingLabel)"
  $buildCommitPendingLine = "- $($script:BuildCommitLabel)$($script:FullWidthColon)$($script:PendingLabel)"
  $pattern = '(?ms)<!-- package-slot source=(?<source>[0-9a-f]{7,40}) -->\r?\n' +
    [System.Text.RegularExpressions.Regex]::Escape($installerPendingLine) + '\r?\n' +
    [System.Text.RegularExpressions.Regex]::Escape($checksumPendingLine) + '\r?\n' +
    [System.Text.RegularExpressions.Regex]::Escape($buildCommitPendingLine) + '\r?\n<!-- package-slot-end -->'
  $matches = [System.Text.RegularExpressions.Regex]::Matches($content, $pattern)
  if ($matches.Count -ne 1) {
    throw "CHANGELOG.md must contain exactly one pending package slot; found $($matches.Count)."
  }

  $sourceCommit = $matches[0].Groups['source'].Value
  $resolvedSourceCommit = Get-NativeOutput `
    -FilePath $GitExecutable `
    -ArgumentList @('rev-parse', '--verify', "${sourceCommit}^{commit}") `
    -Description 'Validating changelog source commit'
  $expectedSourceCommit = Get-NativeOutput `
    -FilePath $GitExecutable `
    -ArgumentList @('rev-parse', '--verify', "${CurrentCommit}^") `
    -Description 'Reading the changelog commit parent'
  if ($resolvedSourceCommit -ne $expectedSourceCommit) {
    throw "Pending package source '$sourceCommit' must be the direct parent of build commit '$CurrentCommit'."
  }

  $changedPathsOutput = Get-NativeOutput `
    -FilePath $GitExecutable `
    -ArgumentList @('diff', '--name-only', $resolvedSourceCommit, $CurrentCommit, '--') `
    -Description 'Validating the changelog-only commit'
  $changedPaths = @($changedPathsOutput -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if ($changedPaths.Count -ne 1 -or $changedPaths[0] -ne 'CHANGELOG.md') {
    throw "The build commit immediately after '$sourceCommit' must change only CHANGELOG.md; found: $($changedPaths -join ', ')"
  }

  return [pscustomobject]@{
    SourceCommit = $sourceCommit
    OriginalContent = $content
  }
}

function Update-PackageSlot {
  param(
    [Parameter(Mandatory)][string] $SourceCommit,
    [Parameter(Mandatory)][string] $ExpectedContent,
    [Parameter(Mandatory)][string] $InstallerName,
    [Parameter(Mandatory)][string] $Sha256,
    [Parameter(Mandatory)][string] $BuildCommit
  )

  Assert-RegularFileWithoutReparsePoint -Path $script:ChangelogPath
  $content = [System.IO.File]::ReadAllText($script:ChangelogPath)
  if ($content -cne $ExpectedContent) {
    throw 'CHANGELOG.md changed while packaging was running.'
  }

  $installerPendingLine = "- $($script:InstallerLabel)$($script:FullWidthColon)$($script:PendingLabel)"
  $checksumPendingLine = "- SHA-256$($script:FullWidthColon)$($script:PendingLabel)"
  $buildCommitPendingLine = "- $($script:BuildCommitLabel)$($script:FullWidthColon)$($script:PendingLabel)"
  $pattern = '(?ms)<!-- package-slot source=' + [System.Text.RegularExpressions.Regex]::Escape($SourceCommit) + ' -->\r?\n' +
    [System.Text.RegularExpressions.Regex]::Escape($installerPendingLine) + '\r?\n' +
    [System.Text.RegularExpressions.Regex]::Escape($checksumPendingLine) + '\r?\n' +
    [System.Text.RegularExpressions.Regex]::Escape($buildCommitPendingLine) + '\r?\n<!-- package-slot-end -->'
  $matches = [System.Text.RegularExpressions.Regex]::Matches($content, $pattern)
  if ($matches.Count -ne 1) {
    throw 'The pending changelog package slot changed while packaging was running.'
  }

  $newline = if ($content.Contains("`r`n")) { "`r`n" } else { "`n" }
  $replacement = @(
    "<!-- package-slot source=$SourceCommit -->",
    "- $($script:InstallerLabel)$($script:FullWidthColon)``$InstallerName``",
    "- SHA-256$($script:FullWidthColon)``$Sha256``",
    "- $($script:BuildCommitLabel)$($script:FullWidthColon)``$BuildCommit``",
    '<!-- package-slot-end -->'
  ) -join $newline

  $match = $matches[0]
  $updated = $content.Substring(0, $match.Index) + $replacement + $content.Substring($match.Index + $match.Length)
  $temporaryPath = Join-Path $script:RepoRoot ('.CHANGELOG.md.' + [System.Guid]::NewGuid().ToString('N') + '.tmp')
  $backupPath = Join-Path $script:RepoRoot ('.CHANGELOG.md.' + [System.Guid]::NewGuid().ToString('N') + '.bak')
  try {
    Write-FileCreateNew -Path $temporaryPath -Content $updated
    [System.IO.File]::Replace($temporaryPath, $script:ChangelogPath, $backupPath, $true)
    if (Test-Path -LiteralPath $backupPath) {
      [System.IO.File]::Delete($backupPath)
    }
  } finally {
    if (Test-Path -LiteralPath $temporaryPath) {
      [System.IO.File]::Delete($temporaryPath)
    }
    if (Test-Path -LiteralPath $backupPath) {
      [System.IO.File]::Delete($backupPath)
    }
  }
}

function Assert-PeFile {
  param([Parameter(Mandatory)][string] $Path)

  Assert-RegularFileWithoutReparsePoint -Path $Path
  $file = Get-Item -LiteralPath $Path
  if ($file.Length -lt 1MB) {
    throw "PE file is unexpectedly small ($($file.Length) bytes): $Path"
  }

  $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
  try {
    $first = $stream.ReadByte()
    $second = $stream.ReadByte()
  } finally {
    $stream.Dispose()
  }

  if ($first -ne 0x4D -or $second -ne 0x5A) {
    throw "File does not have a valid PE MZ header: $Path"
  }
}

function Assert-FileContainsAsciiText {
  param(
    [Parameter(Mandatory)][string] $Path,
    [Parameter(Mandatory)][string] $Text,
    [Parameter(Mandatory)][string] $Description
  )

  if ([string]::IsNullOrWhiteSpace($Text) -or $Text -match '[^\x00-\x7F]') {
    throw "The expected $Description must be non-empty ASCII text."
  }

  $chunkSize = 1MB
  $overlapSize = $Text.Length - 1
  $buffer = New-Object byte[] ($chunkSize + $overlapSize)
  $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
  $carryLength = 0
  $found = $false
  try {
    while (($readLength = $stream.Read($buffer, $carryLength, $chunkSize)) -gt 0) {
      $totalLength = $carryLength + $readLength
      $chunkText = [System.Text.Encoding]::ASCII.GetString($buffer, 0, $totalLength)
      if ($chunkText.IndexOf($Text, [System.StringComparison]::Ordinal) -ge 0) {
        $found = $true
        break
      }

      $carryLength = [System.Math]::Min($overlapSize, $totalLength)
      if ($carryLength -gt 0) {
        [System.Array]::Copy($buffer, $totalLength - $carryLength, $buffer, 0, $carryLength)
      }
    }
  } finally {
    $stream.Dispose()
  }

  if (-not $found) {
    throw "The built application does not contain the expected $Description '$Text': $Path"
  }
}

function Remove-StaleBuildFile {
  param(
    [Parameter(Mandatory)][string] $Path,
    [Parameter(Mandatory)][string] $Description
  )

  $normalizedPath = Get-NormalizedPath -Path $Path
  $targetPrefix = $script:TargetDirectory + [System.IO.Path]::DirectorySeparatorChar
  if (-not $normalizedPath.StartsWith($targetPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to remove $Description outside the target directory: $normalizedPath"
  }

  Assert-PathComponentsAreNotReparsePoints -Path $normalizedPath
  if (-not (Test-Path -LiteralPath $normalizedPath)) {
    return
  }

  Assert-RegularFileWithoutReparsePoint -Path $normalizedPath
  [System.IO.File]::Delete($normalizedPath)
  if (Test-Path -LiteralPath $normalizedPath) {
    throw "Failed to remove stale ${Description}: $normalizedPath"
  }
}

function Copy-FileCreateNew {
  param(
    [Parameter(Mandatory)][string] $Source,
    [Parameter(Mandatory)][string] $Destination
  )

  $input = $null
  $output = $null
  $destinationCreated = $false
  try {
    $input = [System.IO.File]::Open($Source, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $output = [System.IO.File]::Open($Destination, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    $destinationCreated = $true
    $input.CopyTo($output)
    $output.Flush($true)
  } catch {
    if ($null -ne $output) {
      $output.Dispose()
      $output = $null
    }
    if ($destinationCreated -and (Test-Path -LiteralPath $Destination)) {
      [System.IO.File]::Delete($Destination)
    }
    throw
  } finally {
    if ($null -ne $output) {
      $output.Dispose()
    }
    if ($null -ne $input) {
      $input.Dispose()
    }
  }
}

function Write-FileCreateNew {
  param(
    [Parameter(Mandatory)][string] $Path,
    [Parameter(Mandatory)][string] $Content
  )

  $stream = $null
  $writer = $null
  $writeError = $null
  $pathCreated = $false
  try {
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    $pathCreated = $true
    $writer = [System.IO.StreamWriter]::new($stream, $script:Utf8NoBom)
    $stream = $null
    $writer.Write($Content)
    $writer.Flush()
  } catch {
    $writeError = $_
  } finally {
    if ($null -ne $writer) {
      $writer.Dispose()
    }
    if ($null -ne $stream) {
      $stream.Dispose()
    }
  }

  if ($null -ne $writeError) {
    if ($pathCreated -and (Test-Path -LiteralPath $Path)) {
      [System.IO.File]::Delete($Path)
    }
    throw $writeError
  }
}

function Publish-Installer {
  param(
    [Parameter(Mandatory)][string] $SourcePath,
    [Parameter(Mandatory)][string] $UniqueSuffix,
    [Parameter(Mandatory)][string] $ExpectedCommit,
    [Parameter(Mandatory)][hashtable] $InstallerSnapshot
  )

  if ($UniqueSuffix -notmatch '^\d{8}-\d{6}_[0-9a-f]{7,40}$') {
    throw "Invalid package suffix '$UniqueSuffix'."
  }
  if (-not $UniqueSuffix.EndsWith("_$ExpectedCommit", [System.StringComparison]::Ordinal)) {
    throw "Package suffix '$UniqueSuffix' does not contain the current commit '$ExpectedCommit'."
  }

  Assert-PeFile -Path $SourcePath
  Ensure-DistDirectory

  $sourceName = [System.IO.Path]::GetFileNameWithoutExtension($SourcePath)
  $installerName = "${sourceName}_${UniqueSuffix}.exe"
  $installerPath = Join-Path $script:DistDirectory $installerName

  if (Test-Path -LiteralPath $installerPath) {
    throw "Refusing to overwrite existing installer: $installerPath"
  }

  $installerCreated = $false
  try {
    $sourceLength = (Get-Item -LiteralPath $SourcePath).Length
    $sourceHashBefore = (Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash

    Copy-FileCreateNew -Source $SourcePath -Destination $installerPath
    $installerCreated = $true

    Assert-PeFile -Path $installerPath
    $destinationLength = (Get-Item -LiteralPath $installerPath).Length
    $destinationHash = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash
    $sourceHashAfter = (Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash
    if ($sourceLength -ne $destinationLength -or $sourceHashBefore -ne $destinationHash -or $sourceHashBefore -ne $sourceHashAfter) {
      throw 'Installer length or SHA-256 changed during publication.'
    }

    Assert-InstallerSnapshotPreserved -Before $InstallerSnapshot -ExpectedNewFiles @($installerName)
    $finalDestinationHash = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash
    if ($finalDestinationHash -ne $destinationHash) {
      throw 'Published installer changed during final verification.'
    }

    return [pscustomobject]@{
      InstallerName = $installerName
      InstallerPath = $installerPath
      Length = $destinationLength
      Sha256 = $destinationHash
    }
  } catch {
    if ($installerCreated -and (Test-Path -LiteralPath $installerPath)) {
      [System.IO.File]::Delete($installerPath)
    }
    throw
  }
}

function Assert-PublishedPackage {
  param(
    [Parameter(Mandatory)] $PackageResult,
    [Parameter(Mandatory)][hashtable] $InstallerSnapshot
  )

  Assert-PeFile -Path $PackageResult.InstallerPath
  $installer = Get-Item -LiteralPath $PackageResult.InstallerPath
  $installerHash = (Get-FileHash -LiteralPath $PackageResult.InstallerPath -Algorithm SHA256).Hash

  if ($installer.Length -ne $PackageResult.Length -or $installerHash -ne $PackageResult.Sha256) {
    throw 'The published installer changed after its initial verification.'
  }

  Assert-InstallerSnapshotPreserved `
    -Before $InstallerSnapshot `
    -ExpectedNewFiles @($PackageResult.InstallerName)
  Assert-DistContainsInstallersOnly
}

function Get-MutexName {
  $sha256 = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($script:RepoRoot.ToLowerInvariant())
    $hash = $sha256.ComputeHash($bytes)
  } finally {
    $sha256.Dispose()
  }

  $id = ([System.BitConverter]::ToString($hash)).Replace('-', '').Substring(0, 24)
  return "Local\MotrixNextPackage_$id"
}

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
  throw 'This packaging script currently supports Windows only.'
}
if (-not (Test-Path -LiteralPath $script:PackageJsonPath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $script:CargoManifestPath -PathType Leaf)) {
  throw "The script must remain in the Motrix Next repository root: $script:RepoRoot"
}
Assert-PathComponentsAreNotReparsePoints -Path $script:RepoRoot
Assert-PathComponentsAreNotReparsePoints -Path $script:TauriRoot

$mutex = New-Object System.Threading.Mutex($false, (Get-MutexName))
$mutexAcquired = $false
$hadCargoTargetDirectory = Test-Path Env:CARGO_TARGET_DIR
$previousCargoTargetDirectory = if ($hadCargoTargetDirectory) { $env:CARGO_TARGET_DIR } else { $null }
$hadCargoBuildTarget = Test-Path Env:CARGO_BUILD_TARGET
$previousCargoBuildTarget = if ($hadCargoBuildTarget) { $env:CARGO_BUILD_TARGET } else { $null }

try {
  try {
    $mutexAcquired = $mutex.WaitOne(0)
  } catch [System.Threading.AbandonedMutexException] {
    $mutexAcquired = $true
  }
  if (-not $mutexAcquired) {
    throw 'Another package-and-clean process is already running for this repository.'
  }

  if ($Action -eq 'CleanOnly') {
    Write-Step -Message 'Cleaning generated files only'
    Invoke-GeneratedCleanup
    Write-Host "`nCleanup completed. Existing installers and dependencies were preserved; dist contains installers only." -ForegroundColor Green
    return
  }

  $git = Resolve-Executable -Name 'git'
  $node = Resolve-Executable -Name 'node'
  $cargo = Resolve-Executable -Name 'cargo'
  $rustc = Resolve-Executable -Name 'rustc'
  $rustup = Resolve-Executable -Name 'rustup'

  Write-Step -Message 'Validating repository state'
  $repositoryIdentity = Get-ValidatedRepositoryIdentity -GitExecutable $git
  $currentCommit = $repositoryIdentity.Commit
  $shortCommit = $repositoryIdentity.ShortCommit

  $pendingSlot = Get-PendingPackageSlot -GitExecutable $git -CurrentCommit $currentCommit

  $packageJson = Get-Content -LiteralPath $script:PackageJsonPath -Raw | ConvertFrom-Json
  $packageManagerSpec = [string] $packageJson.packageManager
  if ($packageManagerSpec -notmatch '^pnpm@(?<version>\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)$') {
    throw "package.json must pin an exact pnpm version; found '$packageManagerSpec'."
  }
  $pnpmVersion = $Matches['version']

  $cargoMetadataJson = Get-NativeOutput `
    -FilePath $cargo `
    -ArgumentList @('metadata', '--no-deps', '--format-version', '1', '--manifest-path', $script:CargoManifestPath) `
    -Description 'Reading Cargo package metadata'
  $cargoMetadata = $cargoMetadataJson | ConvertFrom-Json
  $matchingPackages = @($cargoMetadata.packages | Where-Object {
      (Get-NormalizedPath -Path ([string] $_.manifest_path)) -eq (Get-NormalizedPath -Path $script:CargoManifestPath)
    })
  if ($matchingPackages.Count -ne 1) {
    throw "Cargo metadata must contain exactly one package for '$script:CargoManifestPath'."
  }
  $version = [string] $matchingPackages[0].version
  if ([string] $packageJson.version -ne $version) {
    throw "Version mismatch: package.json=$($packageJson.version), Cargo.toml=$version."
  }
  $binaryTargets = @($matchingPackages[0].targets | Where-Object { @($_.kind) -contains 'bin' })
  if ($binaryTargets.Count -ne 1) {
    throw "Cargo metadata must contain exactly one binary target; found $($binaryTargets.Count)."
  }
  $binaryName = [string] $binaryTargets[0].name
  if ([string]::IsNullOrWhiteSpace($binaryName) -or $binaryName.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) {
    throw "Invalid Cargo binary target name '$binaryName'."
  }

  $tauriConfig = Get-Content -LiteralPath $script:TauriConfigPath -Raw | ConvertFrom-Json
  $productName = [string] $tauriConfig.productName
  if ([string]::IsNullOrWhiteSpace($productName) -or $productName.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) {
    throw "Invalid Tauri productName '$productName'."
  }

  $targetTriple = if ($Architecture -eq 'arm64') { 'aarch64-pc-windows-msvc' } else { 'x86_64-pc-windows-msvc' }
  $architectureLabel = if ($Architecture -eq 'arm64') { 'arm64' } else { 'x64' }
  $sidecarPath = Join-Path $script:TauriRoot "binaries/motrix-next-engine-$targetTriple.exe"
  if (-not (Test-Path -LiteralPath $sidecarPath -PathType Leaf)) {
    throw "Required sidecar is missing: $sidecarPath"
  }

  $rustcDetails = Get-NativeOutput -FilePath $rustc -ArgumentList @('-vV') -Description 'Reading Rust host target'
  if ($rustcDetails -notmatch '(?m)^host:\s*(?<host>\S+)\s*$') {
    throw 'Unable to determine the Rust host target.'
  }
  $testTargetTriple = $Matches['host']

  $installedTargets = Get-NativeOutput -FilePath $rustup -ArgumentList @('target', 'list', '--installed') -Description 'Reading installed Rust targets'
  if (($installedTargets -split '\r?\n') -notcontains $targetTriple) {
    throw "Rust target '$targetTriple' is not installed. Run: rustup target add $targetTriple"
  }
  if (($installedTargets -split '\r?\n') -notcontains $testTargetTriple) {
    throw "Rust host target '$testTargetTriple' is not installed."
  }

  $nodeVersion = Get-NativeOutput -FilePath $node -ArgumentList @('--version') -Description 'Checking Node.js version'
  if ($nodeVersion -notmatch '^v(?<major>\d+)\.' -or [int] $Matches['major'] -lt 22) {
    throw "Node.js 22 or newer is required; found '$nodeVersion'."
  }
  [void] (Get-NativeOutput -FilePath $cargo -ArgumentList @('--version') -Description 'Checking Cargo')
  [void] (Get-NativeOutput -FilePath $rustc -ArgumentList @('--version') -Description 'Checking rustc')

  $driveRoot = [System.IO.Path]::GetPathRoot($script:RepoRoot)
  $drive = New-Object System.IO.DriveInfo($driveRoot)
  if ($drive.AvailableFreeSpace -lt 20GB) {
    throw ('At least 20 GiB of free disk space is required; {0:N2} GiB is available.' -f ($drive.AvailableFreeSpace / 1GB))
  }

  Initialize-Pnpm -PackageManagerSpec $packageManagerSpec -ExpectedVersion $pnpmVersion

  Ensure-DistDirectory
  Remove-NonInstallerDistContent
  $installerSnapshot = Get-InstallerSnapshot

  if (Test-Path -LiteralPath $script:TargetDirectory) {
    Assert-DirectoryHasNoReparsePoints -Path $script:TargetDirectory
  }
  [void] [System.IO.Directory]::CreateDirectory($script:TargetDirectory)

  $packageWorkDirectory = Join-Path $script:TargetDirectory 'package-work'
  if (Test-Path -LiteralPath $packageWorkDirectory) {
    $normalizedWorkDirectory = Get-NormalizedPath -Path $packageWorkDirectory
    [void] $script:AllowedCleanupDirectories.Add($normalizedWorkDirectory)
    Remove-SafeDirectory -Path $normalizedWorkDirectory
  }
  [void] [System.IO.Directory]::CreateDirectory($packageWorkDirectory)
  $frontendDirectory = Join-Path $packageWorkDirectory 'frontend'
  $frontendDistRelativePath = 'target/package-work/frontend'
  $overlayConfigPath = Join-Path $packageWorkDirectory 'tauri.package.conf.json'

  # Tauri deserializes URL before directory, so a Windows drive path disables asset embedding.
  $frontendDistUri = $null
  if ([System.IO.Path]::IsPathRooted($frontendDistRelativePath) -or
      [System.Uri]::TryCreate($frontendDistRelativePath, [System.UriKind]::Absolute, [ref] $frontendDistUri)) {
    throw "The packaging frontendDist must be a relative directory path: $frontendDistRelativePath"
  }
  $resolvedFrontendDist = Get-NormalizedPath -Path (Join-Path $script:TauriRoot $frontendDistRelativePath)
  if ($resolvedFrontendDist -ne (Get-NormalizedPath -Path $frontendDirectory)) {
    throw "The packaging frontendDist resolves to '$resolvedFrontendDist' instead of '$frontendDirectory'."
  }

  $env:CARGO_TARGET_DIR = $script:TargetDirectory
  $env:CARGO_BUILD_TARGET = $targetTriple

  $packageResult = $null
  $packageFailure = $null
  try {
    Invoke-Pnpm -PnpmArguments @('install', '--frozen-lockfile') -Description 'Installing pinned frontend dependencies'
    Invoke-Pnpm -PnpmArguments @('lint') -Description 'Running ESLint'
    Invoke-Pnpm -PnpmArguments @('format:check') -Description 'Checking frontend formatting'
    Invoke-Pnpm -PnpmArguments @('check:repo') -Description 'Checking repository and locale integrity'
    Invoke-Pnpm -PnpmArguments @('exec', 'vue-tsc', '--noEmit') -Description 'Running TypeScript type checks'
    Invoke-Pnpm -PnpmArguments @('test') -Description 'Running frontend tests'

    Invoke-NativeCommand -FilePath $cargo -ArgumentList @('fmt', '--manifest-path', $script:CargoManifestPath, '--all', '--', '--check') -Description 'Checking Rust formatting'
    Invoke-NativeCommand -FilePath $cargo -ArgumentList @('clippy', '--manifest-path', $script:CargoManifestPath, '--all-targets', '--target', $targetTriple, '--', '-D', 'warnings') -Description 'Running Rust Clippy'
    Invoke-NativeCommand -FilePath $cargo -ArgumentList @('check', '--manifest-path', $script:CargoManifestPath, '--all-targets', '--target', $targetTriple) -Description 'Running Rust checks'
    Invoke-NativeCommand -FilePath $cargo -ArgumentList @('test', '--manifest-path', $script:CargoManifestPath, '--all-targets', '--target', $testTargetTriple) -Description 'Running Rust tests on the host target'

    Invoke-Pnpm `
      -PnpmArguments @('exec', 'vite', 'build', '--outDir', $frontendDirectory, '--emptyOutDir') `
      -Description 'Building isolated frontend assets'
    $frontendIndex = Join-Path $frontendDirectory 'index.html'
    if (-not (Test-Path -LiteralPath $frontendIndex -PathType Leaf) -or (Get-Item -LiteralPath $frontendIndex).Length -eq 0) {
      throw "Isolated frontend build did not produce a valid index.html: $frontendIndex"
    }
    $frontendEntryScripts = @(Get-ChildItem -LiteralPath (Join-Path $frontendDirectory 'assets') -File -Filter 'main-*.js')
    if ($frontendEntryScripts.Count -ne 1) {
      throw "Isolated frontend build must produce exactly one main JavaScript entry; found $($frontendEntryScripts.Count)."
    }
    $frontendEntryName = $frontendEntryScripts[0].Name
    $frontendIndexContent = [System.IO.File]::ReadAllText($frontendIndex)
    if ($frontendIndexContent.IndexOf($frontendEntryName, [System.StringComparison]::Ordinal) -lt 0) {
      throw "Isolated frontend index.html does not reference '$frontendEntryName'."
    }

    $overlay = [ordered]@{
      build = [ordered]@{
        beforeBuildCommand = $null
        frontendDist = $frontendDistRelativePath
      }
      bundle = [ordered]@{
        createUpdaterArtifacts = $false
      }
    }
    $overlayJson = $overlay | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($overlayConfigPath, $overlayJson, $script:Utf8NoBom)

    $expectedInstallerName = "${productName}_${version}_${architectureLabel}-setup.exe"
    $rawApplicationPath = Join-Path $script:TargetDirectory "$targetTriple/release/$binaryName.exe"
    $rawInstallerPath = Join-Path $script:TargetDirectory "$targetTriple/release/bundle/nsis/$expectedInstallerName"
    Remove-StaleBuildFile -Path $rawApplicationPath -Description 'raw application executable'
    Remove-StaleBuildFile -Path $rawInstallerPath -Description 'raw installer'

    $tauriBuildStartedUtc = [System.DateTime]::UtcNow
    Invoke-Pnpm `
      -PnpmArguments @('tauri', 'build', '--target', $targetTriple, '--bundles', 'nsis', '--ci', '--no-sign', '--config', $overlayConfigPath) `
      -Description 'Building unsigned Windows NSIS installer'

    if (-not (Test-Path -LiteralPath $rawApplicationPath -PathType Leaf)) {
      throw "Expected application executable was not generated: $rawApplicationPath"
    }
    if (-not (Test-Path -LiteralPath $rawInstallerPath -PathType Leaf)) {
      throw "Expected NSIS installer was not generated: $rawInstallerPath"
    }
    Assert-PathComponentsAreNotReparsePoints -Path $rawApplicationPath
    Assert-PathComponentsAreNotReparsePoints -Path $rawInstallerPath
    Assert-RegularFileWithoutReparsePoint -Path $rawApplicationPath
    Assert-RegularFileWithoutReparsePoint -Path $rawInstallerPath
    $rawApplicationItem = Get-Item -LiteralPath $rawApplicationPath
    $rawInstallerItem = Get-Item -LiteralPath $rawInstallerPath
    if ($rawApplicationItem.LastWriteTimeUtc -lt $tauriBuildStartedUtc.AddSeconds(-5)) {
      throw "The application executable does not appear to come from the current build: $rawApplicationPath"
    }
    if ($rawInstallerItem.LastWriteTimeUtc -lt $tauriBuildStartedUtc.AddSeconds(-5)) {
      throw "The NSIS installer does not appear to come from the current build: $rawInstallerPath"
    }
    Assert-PeFile -Path $rawApplicationPath
    Assert-FileContainsAsciiText `
      -Path $rawApplicationPath `
      -Text $frontendEntryName `
      -Description 'embedded frontend entry'

    Write-Step -Message 'Revalidating repository identity before publication'
    [void] (Get-ValidatedRepositoryIdentity `
        -GitExecutable $git `
        -ExpectedCommit $currentCommit `
        -ExpectedShortCommit $shortCommit)

    $timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
    $uniqueSuffix = "${timestamp}_${shortCommit}"
    $packageResult = Publish-Installer `
      -SourcePath $rawInstallerPath `
      -UniqueSuffix $uniqueSuffix `
      -ExpectedCommit $shortCommit `
      -InstallerSnapshot $installerSnapshot
  } catch {
    $packageFailure = $_
  }

  $cleanupFailure = $null
  if ($null -eq $packageFailure -or -not $KeepTemporaryOnFailure) {
    try {
      Write-Step -Message 'Cleaning generated files'
      Invoke-GeneratedCleanup
    } catch {
      $cleanupFailure = $_
    }
  } else {
    Write-Warning "Packaging failed; temporary files were retained at '$script:TargetDirectory'."
  }

  if ($null -ne $packageFailure) {
    if ($null -ne $cleanupFailure) {
      throw "Packaging failed: $($packageFailure.Exception.Message)$([Environment]::NewLine)Cleanup also failed: $($cleanupFailure.Exception.Message)"
    }
    throw $packageFailure
  }

  $finalizationFailure = $null
  try {
    Write-Step -Message 'Revalidating published package before changelog update'
    Assert-PublishedPackage -PackageResult $packageResult -InstallerSnapshot $installerSnapshot

    Write-Step -Message 'Revalidating repository identity before changelog update'
    [void] (Get-ValidatedRepositoryIdentity `
        -GitExecutable $git `
        -ExpectedCommit $currentCommit `
        -ExpectedShortCommit $shortCommit)

    Update-PackageSlot `
      -SourceCommit $pendingSlot.SourceCommit `
      -ExpectedContent $pendingSlot.OriginalContent `
      -InstallerName $packageResult.InstallerName `
      -Sha256 $packageResult.Sha256 `
      -BuildCommit $shortCommit

    $postStatus = Get-NativeOutput -FilePath $git -ArgumentList @('status', '--short', '--untracked-files=all') -Description 'Checking final worktree state'
    $statusLines = @($postStatus -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($statusLines.Count -ne 1 -or $statusLines[0] -notmatch '^ M CHANGELOG\.md$') {
      throw "Only CHANGELOG.md should be modified after packaging; found:$([Environment]::NewLine)$postStatus"
    }
  } catch {
    $finalizationFailure = $_
  }

  if ($null -ne $finalizationFailure) {
    Write-Host "Published installer retained at: $($packageResult.InstallerPath)" -ForegroundColor Yellow
    Write-Host "Initially verified SHA-256: $($packageResult.Sha256)" -ForegroundColor Yellow
    if ($null -ne $cleanupFailure) {
      throw "Package finalization failed: $($finalizationFailure.Exception.Message)$([Environment]::NewLine)Cleanup also failed: $($cleanupFailure.Exception.Message)"
    }
    throw $finalizationFailure
  }
  if ($null -ne $cleanupFailure) {
    Write-Host "Verified installer retained at: $($packageResult.InstallerPath)" -ForegroundColor Yellow
    Write-Host "SHA-256: $($packageResult.Sha256)" -ForegroundColor Yellow
    Write-Host 'CHANGELOG.md was updated with the verified package metadata.' -ForegroundColor Yellow
    throw $cleanupFailure
  }

  Write-Host "`nPackage completed successfully." -ForegroundColor Green
  Write-Host "Installer: $($packageResult.InstallerPath)"
  Write-Host "Size: $($packageResult.Length) bytes"
  Write-Host "SHA-256: $($packageResult.Sha256)"
  Write-Host 'Temporary build output and non-installer dist content were removed; node_modules and toolchain caches were preserved.'
  Write-Host 'CHANGELOG.md was updated and must be committed separately.'
} finally {
  if ($hadCargoTargetDirectory) {
    $env:CARGO_TARGET_DIR = $previousCargoTargetDirectory
  } else {
    Remove-Item Env:CARGO_TARGET_DIR -ErrorAction SilentlyContinue
  }
  if ($hadCargoBuildTarget) {
    $env:CARGO_BUILD_TARGET = $previousCargoBuildTarget
  } else {
    Remove-Item Env:CARGO_BUILD_TARGET -ErrorAction SilentlyContinue
  }

  if ($mutexAcquired) {
    [void] $mutex.ReleaseMutex()
  }
  $mutex.Dispose()
}
