[CmdletBinding()]
param(
    [switch]$AcknowledgeKnownAvastBlocker,
    [string]$FlutterRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$script:Started = [Diagnostics.Stopwatch]::StartNew()
$script:ThisScriptPath = $PSCommandPath
$script:RepoRoot = $null
$script:Version = $null
$script:ReleaseSourceSha = $null
$script:Preflight = $null
$script:PreflightExit = $null
$script:NativeStatus = 'NOT_RUN'
$script:ParameterEnvironmentStatus = 'NOT_RUN'
$script:ParameterHashStatus = 'NOT_RUN'
$script:MsvcEnvironmentStatus = 'NOT_RUN'
$script:BuildUserProfile = $null
$script:BuildParameterDirectory = $null
$script:BuildParameters = @()
$script:FlutterStatus = 'NOT_RUN'
$script:VerificationStatus = 'NOT_RUN'
$script:Warnings = [Collections.Generic.List[string]]::new()
$script:EnvironmentalBlockers = [Collections.Generic.List[string]]::new()
$script:FinalDirectory = $null
$script:ManifestPath = $null
$script:ResultPath = $null
$script:Artifacts = @()
$script:StageDirectory = $null
$script:FailureMessage = $null

function Write-Stage {
    param([string]$Name, [string]$Purpose, [scriptblock]$Action)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    Write-Host "[$Name] START - $Purpose"
    try {
        & $Action
        $timer.Stop()
        Write-Host ("[$Name] PASS - {0} ms" -f $timer.ElapsedMilliseconds)
    } catch {
        $timer.Stop()
        Write-Host ("[$Name] FAIL - {0} ms - {1}" -f $timer.ElapsedMilliseconds, $_.Exception.Message)
        throw
    }
}

function Invoke-Streaming {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory)][string]$WorkingDirectory
    )
    $old = (Get-Location).Path
    $oldErrorActionPreference = $ErrorActionPreference
    $lines = [Collections.Generic.List[string]]::new()
    try {
        Set-Location -LiteralPath $WorkingDirectory
        $ErrorActionPreference = 'Continue'
        & $FilePath @Arguments 2>&1 | ForEach-Object {
            $line = $_.ToString()
            $lines.Add($line)
            Write-Host $line
        }
        $code = $LASTEXITCODE
        if ($null -eq $code) { $code = 0 }
        [pscustomobject]@{ ExitCode = [int]$code; Output = ($lines -join "`n") }
    } finally {
        $ErrorActionPreference = $oldErrorActionPreference
        Set-Location -LiteralPath $old
    }
}

function Invoke-Git {
    param([string[]]$Arguments)
    $result = Invoke-Streaming -FilePath (Get-Command git -ErrorAction Stop).Source -Arguments $Arguments -WorkingDirectory $script:RepoRoot
    if ($result.ExitCode -ne 0) { throw "git failed ($($result.ExitCode)): git $($Arguments -join ' ')" }
    $result.Output.Trim()
}

function Import-VsDevEnvironment {
    param([Parameter(Mandatory)][string]$VsDevCmd)
    if (-not (Test-Path -LiteralPath $VsDevCmd -PathType Leaf)) { throw "VsDevCmd.bat is missing: $VsDevCmd" }
    if ((Get-Item -LiteralPath $VsDevCmd).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'VsDevCmd.bat must not be a reparse point.' }
    if ($VsDevCmd.IndexOfAny([char[]]@('"',"`r","`n")) -ge 0) { throw 'VsDevCmd.bat path contains unsafe command characters.' }
    $command = 'call "' + $VsDevCmd + '" -arch=x64 -host_arch=x64 >nul && set'
    $old = (Get-Location).Path
    try {
        Set-Location -LiteralPath $script:RepoRoot
        $lines = @(& $env:ComSpec /d /s /c $command 2>&1 | ForEach-Object { $_.ToString() })
        $code = $LASTEXITCODE
    } finally {
        Set-Location -LiteralPath $old
    }
    if ($code -ne 0) { throw "VsDevCmd.bat failed with exit $code." }
    foreach ($line in $lines) {
        if ($line -match '^([^=]+)=(.*)$') { [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process') }
    }
}

function Get-FullPath {
    param([Parameter(Mandatory)][string]$Path)
    [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
}

function Assert-DirectChildBoundary {
    param([string]$Path, [string]$RequiredParent)
    $full = Get-FullPath $Path
    $parent = Get-FullPath (Split-Path -Parent $full)
    $required = Get-FullPath $RequiredParent
    if (-not $parent.Equals($required, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe path boundary: '$full' is not a direct child of '$required'."
    }
    $full
}

function Assert-BeneathBoundary {
    param([string]$Path, [string]$RequiredRoot)
    $full = Get-FullPath $Path
    $root = (Get-FullPath $RequiredRoot) + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe path boundary: '$full' is not beneath '$RequiredRoot'."
    }
    $full
}

function Get-FileEvidence {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$RelativeTo)
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    $baseUri = [Uri]((Get-FullPath $RelativeTo) + [IO.Path]::DirectorySeparatorChar)
    $itemUri = [Uri](Get-FullPath $item.FullName)
    [pscustomobject][ordered]@{
        relative_path = [Uri]::UnescapeDataString($baseUri.MakeRelativeUri($itemUri).ToString()).Replace('/', '\')
        sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        size = [long]$item.Length
    }
}

function Get-Check {
    param([string]$Id)
    @($script:Preflight.checks | Where-Object { $_.id -eq $Id }) | Select-Object -First 1
}

function Get-DumpbinOutput {
    param([string]$Dumpbin, [string]$Mode, [string]$Path)
    $result = Invoke-Streaming -FilePath $Dumpbin -Arguments @($Mode, $Path) -WorkingDirectory $script:RepoRoot
    if ($result.ExitCode -ne 0) { throw "dumpbin $Mode failed for a release artifact: $Path" }
    $result.Output
}

function Get-PeEvidence {
    param([string]$Dumpbin, [string]$Path, [switch]$RequireGui, [switch]$RequireInitWallet)
    $headers = Get-DumpbinOutput $Dumpbin '/headers' $Path
    $dependents = Get-DumpbinOutput $Dumpbin '/dependents' $Path
    $exports = Get-DumpbinOutput $Dumpbin '/exports' $Path
    if ($headers -notmatch '(?im)^\s*8664 machine \(x64\)\s*$') { throw "PE machine is not 8664/x64: $Path" }
    if ($RequireGui -and $headers -notmatch '(?im)^\s*2 subsystem \(Windows GUI\)\s*$') { throw "PE subsystem is not Windows GUI (2): $Path" }
    if ($RequireGui -and $headers -notmatch '(?im)\.rsrc') { throw "PE resource section/icon evidence is absent: $Path" }
    $exportNames = @($exports -split "`r?`n" | ForEach-Object {
        if ($_ -match '^\s*\d+\s+[0-9A-F]+\s+[0-9A-F]+\s+([^\s=]+)(?:\s+=\s+\S+)?\s*$') { $Matches[1] }
    })
    if ($RequireInitWallet -and $exportNames -notcontains 'init_wallet') {
        throw "Exact selected ABI sentinel 'init_wallet' was not exported by $Path"
    }
    $imports = @($dependents -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '(?i)^[A-Z0-9_.+-]+\.dll$' } | Sort-Object -Unique)
    [pscustomobject][ordered]@{ path = $Path; machine = '8664 / x64'; subsystem = $(if ($RequireGui) { '2 / Windows GUI' } else { $null }); imports = $imports; selected_abi_sentinel = $(if ($RequireInitWallet) { 'init_wallet' } else { $null }) }
}

function Write-MachineResult {
    param([string]$Status)
    if (-not $script:ResultPath) { return }
    $parent = Split-Path -Parent $script:ResultPath
    if (-not (Test-Path -LiteralPath $parent)) { [void](New-Item -ItemType Directory -Path $parent) }
    $result = [pscustomobject][ordered]@{
        status = $Status
        source_sha = $script:ReleaseSourceSha
        preflight_exit_code = $script:PreflightExit
        native_build_status = $script:NativeStatus
        parameter_environment_status = $script:ParameterEnvironmentStatus
        parameter_hash_validation_status = $script:ParameterHashStatus
        msvc_environment_status = $script:MsvcEnvironmentStatus
        flutter_build_status = $script:FlutterStatus
        verification_status = $script:VerificationStatus
        release_directory = $script:FinalDirectory
        manifest_path = $script:ManifestPath
        artifacts = $script:Artifacts
        warnings = @($script:Warnings)
        environmental_blockers = @($script:EnvironmentalBlockers)
        operator_acknowledgements = [pscustomobject]@{ known_avast_blocker = [bool]$AcknowledgeKnownAvastBlocker }
        elapsed_ms = [long]$script:Started.ElapsedMilliseconds
        failure = $script:FailureMessage
    }
    [IO.File]::WriteAllText($script:ResultPath, ($result | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
}

try {
    Write-Stage 'REPOSITORY' 'Validate the authoritative source root and capture immutable release identity' {
        if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'This release pipeline requires Windows.' }
        $scriptPath = $script:ThisScriptPath
        $candidateRoot = (& (Get-Command git -ErrorAction Stop).Source -C (Split-Path -Parent $scriptPath) rev-parse --show-toplevel 2>$null).Trim()
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $candidateRoot -PathType Container)) { throw 'Unable to resolve repository root.' }
        $script:RepoRoot = Get-FullPath $candidateRoot
        if ((Get-FullPath (Split-Path -Parent (Split-Path -Parent $scriptPath))) -ne $script:RepoRoot) { throw 'Script location does not match repository root.' }
        $script:ReleaseSourceSha = (Invoke-Git @('rev-parse', 'HEAD')).Trim()
        if ($script:ReleaseSourceSha -notmatch '^[0-9a-f]{40}$') { throw 'Invalid Git source SHA.' }
        $dirty = Invoke-Git @('-c', 'core.optionalLocks=false', 'status', '--porcelain=v1', '-uall')
        if ($dirty) { throw 'Release source must be fully clean.' }
        $pubspec = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'pubspec.yaml') -Raw
        if ($pubspec -notmatch '(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)\s*$') { throw 'pubspec.yaml has no supported version name/build number.' }
        $script:Version = "$($Matches[1])+$($Matches[2])"
        $versionRoot = Join-Path $script:RepoRoot "dist\windows\$($script:Version)"
        $script:FinalDirectory = Join-Path $versionRoot 'BUCK-Wallet'
        $script:ManifestPath = Join-Path $script:FinalDirectory 'BUCK-Wallet-build-manifest.json'
        $script:ResultPath = Join-Path $versionRoot 'BUCK-Wallet-build-result.json'
        if (Test-Path -LiteralPath $script:FinalDirectory) { throw "Final release destination already exists: dist\windows\$($script:Version)\BUCK-Wallet" }
    }

    Write-Stage 'PREFLIGHT' 'Run the complete accepted P4 ReleasePreflight offline' {
        $preflightScript = Join-Path $script:RepoRoot 'tool\windows_preflight.ps1'
        $preflightJson = Join-Path (Split-Path -Parent $script:ResultPath) ('.preflight.' + [Guid]::NewGuid().ToString('N') + '.json')
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $preflightJson) -Force)
        $args = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $preflightScript,
            '-Mode', 'ReleasePreflight', '-NetworkMode', 'Offline', '-ExpectedReleaseSha', $script:ReleaseSourceSha,
            '-OutputFormat', 'Json', '-JsonOutputPath', $preflightJson)
        if ($FlutterRoot) { $args += @('-FlutterRoot', $FlutterRoot) }
        $run = Invoke-Streaming -FilePath (Get-Command powershell.exe -ErrorAction Stop).Source -Arguments $args -WorkingDirectory $script:RepoRoot
        $script:PreflightExit = $run.ExitCode
        if (-not (Test-Path -LiteralPath $preflightJson -PathType Leaf)) { throw 'ReleasePreflight did not produce parseable JSON evidence.' }
        try { $script:Preflight = Get-Content -LiteralPath $preflightJson -Raw | ConvertFrom-Json } finally { Remove-Item -LiteralPath $preflightJson -Force }
        $blockers = @($script:Preflight.checks | Where-Object { $_.classification -eq 'ENVIRONMENTAL_BLOCKER' })
        foreach ($blocker in $blockers) { $script:EnvironmentalBlockers.Add([string]$blocker.id) }
        if ($script:PreflightExit -in @(1, 2)) { throw "ReleasePreflight stopped the build with exit $($script:PreflightExit)." }
        if ($script:PreflightExit -eq 3) {
            if ($blockers.Count -ne 1 -or $blockers[0].id -ne 'AVAST_CARGO_EVOGEN') { throw 'ReleasePreflight reported an unacknowledgeable environmental blocker set.' }
            if (-not $AcknowledgeKnownAvastBlocker) { throw 'The sole known Avast blocker requires explicit -AcknowledgeKnownAvastBlocker.' }
            $script:Warnings.Add('AVAST_CARGO_EVOGEN explicitly acknowledged; this is not AV remediation.')
        } elseif ($script:PreflightExit -ne 0) {
            throw "Unexpected ReleasePreflight exit code: $($script:PreflightExit)"
        }
        $requiredPass = @('CARGO_VERSION','RUST_HOST','VS_IDENTITY','MSVC_VERSION','WINDOWS_SDK','CMAKE_VERSION','FLUTTER_IDENTITY','WINDOWS_RUNNER_STATIC','NATIVE_RUNTIME_STATIC')
        foreach ($id in $requiredPass) {
            $check = Get-Check $id
            if (-not $check -or $check.classification -ne 'PASS') { throw "Required preflight identity did not pass: $id" }
        }
    }

    $baseline = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'tool\windows_preflight.baseline.json') -Raw | ConvertFrom-Json
    $flutterSdk = if ($FlutterRoot) { Get-FullPath $FlutterRoot } else { Get-FullPath ([string]$baseline.flutter.preferred_local_root) }
    $flutterExe = Join-Path $flutterSdk 'bin\flutter.bat'
    $cargoExe = (Get-Command cargo -ErrorAction Stop).Source
    $cargoIdentity = Get-Check 'CARGO_VERSION'
    if ($cargoIdentity.classification -ne 'PASS') { throw 'No preflight-accepted Cargo identity is available.' }
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $vsJson = & $vswhere -latest -products '*' -requires ([string]$baseline.windows_toolchain.workload) -format json -utf8 | ConvertFrom-Json
    $vsRoot = [string]@($vsJson)[0].installationPath
    $vsDevCmd = Join-Path $vsRoot 'Common7\Tools\VsDevCmd.bat'
    $dumpbin = Join-Path $vsRoot "VC\Tools\MSVC\$($baseline.windows_toolchain.msvc)\bin\Hostx64\x64\dumpbin.exe"
    if (-not (Test-Path -LiteralPath $dumpbin -PathType Leaf)) { throw 'Preflight-accepted Visual Studio installation has no expected x64 dumpbin.exe.' }

    $nativeOutput = Join-Path $script:RepoRoot 'target\release\warp_api_ffi.dll'
    $flutterOutputRoot = Join-Path $script:RepoRoot 'build\windows\x64\runner\Release'
    $exeOutput = Join-Path $flutterOutputRoot 'buck-wallet.exe'
    $staleEvidence = [ordered]@{}
    Write-Stage 'PARAMETER_ENVIRONMENT' 'Resolve the deterministic Windows build-time Sapling parameter directory' {
        $script:ParameterEnvironmentStatus = 'FAIL'
        $userProfile = [string]$env:USERPROFILE
        if ([string]::IsNullOrWhiteSpace($userProfile)) { throw 'USERPROFILE is absent or empty; a process-local HOME mapping cannot be established.' }
        if (-not [IO.Path]::IsPathRooted($userProfile) -or $userProfile -notmatch '^[A-Za-z]:\\') { throw "USERPROFILE is not an absolute drive-qualified Windows path: '$userProfile'" }
        $userProfile = Get-FullPath $userProfile
        $profileItem = Get-Item -LiteralPath $userProfile -ErrorAction Stop
        if (-not $profileItem.PSIsContainer) { throw "USERPROFILE is not an existing directory: '$userProfile'" }
        if ($profileItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "USERPROFILE must not be a reparse point: '$userProfile'" }
        if (-not (Get-FullPath $profileItem.FullName).Equals($userProfile, [StringComparison]::OrdinalIgnoreCase)) { throw 'USERPROFILE resolved to an unexpected path.' }

        $script:BuildUserProfile = $userProfile
        $script:BuildParameterDirectory = Assert-DirectChildBoundary (Join-Path $userProfile '.zcash-params') $userProfile
        $parameterDirectoryItem = Get-Item -LiteralPath $script:BuildParameterDirectory -ErrorAction Stop
        if (-not $parameterDirectoryItem.PSIsContainer) { throw "Build-time parameter path is not a directory: '$($script:BuildParameterDirectory)'" }
        if ($parameterDirectoryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Build-time parameter directory must not be a reparse point: '$($script:BuildParameterDirectory)'" }
        $script:ParameterEnvironmentStatus = 'PASS'
    }

    Write-Stage 'PARAMETER_HASH_VALIDATION' 'Validate exact build-time Sapling parameter sizes and SHA-256 identities' {
        $script:ParameterHashStatus = 'FAIL'
        $expectedParameters = @(
            @{ Name='sapling-spend.params'; Size=47958396L; Sha256='8e48ffd23abb3a5fd9c5589204f32d9c31285a04b78096ba40a79b75677efc13' },
            @{ Name='sapling-output.params'; Size=3592860L; Sha256='2f0ebbcbb9bb0bcffe95a397e7eba89c29eb4dde6191c339db88570e3f3fb0e4' }
        )
        $script:BuildParameters = @($expectedParameters | ForEach-Object {
            $path = Assert-DirectChildBoundary (Join-Path $script:BuildParameterDirectory $_.Name) $script:BuildParameterDirectory
            $item = Get-Item -LiteralPath $path -ErrorAction Stop
            if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Build-time parameter must be a regular file: '$path'" }
            $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($item.Length -ne $_.Size) { throw "Build-time parameter size mismatch for '$($_.Name)': expected $($_.Size), observed $($item.Length)." }
            if ($hash -cne $_.Sha256) { throw "Build-time parameter SHA-256 mismatch for '$($_.Name)'." }
            [pscustomobject][ordered]@{ path=$path; size=[long]$item.Length; sha256=$hash }
        })
        $script:ParameterHashStatus = 'PASS'
    }

    Write-Stage 'MSVC_ENVIRONMENT' 'Initialize the accepted Visual Studio x64 developer environment process-locally' {
        $script:MsvcEnvironmentStatus = 'FAIL'
        Import-VsDevEnvironment -VsDevCmd $vsDevCmd
        if ($env:VCToolsVersion.TrimEnd('\\') -ne [string]$baseline.windows_toolchain.msvc) { throw "VsDevCmd selected unexpected VCToolsVersion '$env:VCToolsVersion'." }
        if ($env:WindowsSDKVersion.TrimEnd('\\') -ne [string]$baseline.windows_toolchain.windows_sdk) { throw "VsDevCmd selected unexpected WindowsSDKVersion '$env:WindowsSDKVersion'." }
        $cl = (Get-Command cl.exe -ErrorAction Stop).Source
        if ($cl -notmatch '(?i)\\Hostx64\\x64\\cl\.exe$') { throw "VsDevCmd did not select the Hostx64\\x64 compiler: '$cl'" }
        $script:MsvcEnvironmentStatus = 'PASS'
    }

    Write-Stage 'STALE-DEFENSE' 'Record and remove only the two exact proof artifacts' {
        foreach ($proof in @(
            @{ Path = $nativeOutput; Parent = (Join-Path $script:RepoRoot 'target\release'); Key = 'native_dll' },
            @{ Path = $exeOutput; Parent = $flutterOutputRoot; Key = 'flutter_exe' }
        )) {
            $safe = Assert-DirectChildBoundary $proof.Path $proof.Parent
            $before = if (Test-Path -LiteralPath $safe -PathType Leaf) { Get-FileEvidence $safe $script:RepoRoot } else { $null }
            $staleEvidence[$proof.Key] = $before
            if ($before) { Remove-Item -LiteralPath $safe -Force }
            if (Test-Path -LiteralPath $safe) { throw "Expected proof artifact could not be removed: $safe" }
        }
    }

    Write-Stage 'NATIVE_BUILD' 'Build locked native x64 release runtime with approved features and validated process-local prerequisites' {
        $oldCargoOffline = $env:CARGO_NET_OFFLINE
        $oldHome = $env:HOME
        try {
            $env:CARGO_NET_OFFLINE = 'true'
            # zcash-params/build.rs reads HOME directly. Ignore any inherited HOME and
            # deterministically map only this release process to validated USERPROFILE.
            $env:HOME = $script:BuildUserProfile
            $nativeRun = Invoke-Streaming -FilePath $cargoExe -Arguments @('build','--locked','--release','--features=dart_ffi,sqlcipher') -WorkingDirectory (Join-Path $script:RepoRoot 'native\zcash-sync')
        } finally {
            if ($null -eq $oldCargoOffline) { Remove-Item Env:CARGO_NET_OFFLINE -ErrorAction SilentlyContinue } else { $env:CARGO_NET_OFFLINE = $oldCargoOffline }
            if ($null -eq $oldHome) { Remove-Item Env:HOME -ErrorAction SilentlyContinue } else { $env:HOME = $oldHome }
        }
        if ($nativeRun.ExitCode -ne 0) { $script:NativeStatus = 'FAIL'; throw "Native Cargo release build failed with exit $($nativeRun.ExitCode)." }
        if (-not (Test-Path -LiteralPath $nativeOutput -PathType Leaf)) { $script:NativeStatus = 'FAIL'; throw 'Native proof DLL was not recreated.' }
        $script:NativeStatus = 'PASS'
    }

    $script:NativeEvidence = $null
    Write-Stage 'NATIVE-VERIFY' 'Verify native DLL identity, PE machine, imports, export sentinel, hash and size' {
        $script:NativeEvidence = Get-PeEvidence -Dumpbin $dumpbin -Path $nativeOutput -RequireInitWallet
        $script:NativeEvidence.path = 'warp_api_ffi.dll'
        $script:NativeEvidence | Add-Member -NotePropertyName build_source_path -NotePropertyValue 'target\release\warp_api_ffi.dll'
        $nativeFile = Get-FileEvidence $nativeOutput $script:RepoRoot
        $script:NativeEvidence | Add-Member -NotePropertyName sha256 -NotePropertyValue $nativeFile.sha256
        $script:NativeEvidence | Add-Member -NotePropertyName size -NotePropertyValue $nativeFile.size
    }

    Write-Stage 'FLUTTER-BUILD' 'Build the pinned Flutter Windows release bundle without manual restoration' {
        $flutterRun = Invoke-Streaming -FilePath $flutterExe -Arguments @('build','windows','--release') -WorkingDirectory $script:RepoRoot
        if ($flutterRun.Output -match '(?im)^\s*Downloading packages') {
            $script:FlutterStatus = 'FAIL'
            throw 'Flutter attempted an implicit package download; offline local prerequisites are incomplete.'
        }
        if ($flutterRun.Output -match '(?im)^\s*(Running|Resolving)\s+.*(pub get|dependencies)') {
            $script:Warnings.Add('Flutter build reported an implicit dependency action; no manual restoration was run. Review raw build output.')
        }
        if ($flutterRun.ExitCode -ne 0) { $script:FlutterStatus = 'FAIL'; throw "Flutter Windows release build failed with exit $($flutterRun.ExitCode)." }
        if (-not (Test-Path -LiteralPath $exeOutput -PathType Leaf)) { $script:FlutterStatus = 'FAIL'; throw 'Flutter proof executable was not recreated.' }
        $script:FlutterStatus = 'PASS'
    }

    $pluginContract = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'windows\flutter\generated_plugins.cmake') -Raw
    $pluginBlock = [regex]::Match($pluginContract, '(?s)list\(APPEND FLUTTER_PLUGIN_LIST(.*?)\)').Groups[1].Value
    $pluginNames = @($pluginBlock -split '\s+' | Where-Object { $_ } | ForEach-Object { "${_}_plugin.dll" })
    $acceptedPlugins = @('app_links_plugin.dll','awesome_notifications_plugin.dll','awesome_notifications_core_plugin.dll','connectivity_plus_plugin.dll','file_selector_windows_plugin.dll','local_auth_windows_plugin.dll','screen_retriever_plugin.dll','share_plus_plugin.dll','url_launcher_windows_plugin.dll','window_manager_plugin.dll')
    if ((Compare-Object $acceptedPlugins $pluginNames)) { throw "Tracked plugin contract differs from accepted P5 list. Current: $($pluginNames -join ', ')" }

    Write-Stage 'BUNDLE-VERIFY' 'Verify generated Flutter bundle, product identity, parameters, plugins and PE metadata' {
        foreach ($relative in @('buck-wallet.exe','flutter_windows.dll','data\app.so','data\icudtl.dat','data\flutter_assets','data\flutter_assets\NOTICES.Z') + $pluginNames) {
            if (-not (Test-Path -LiteralPath (Join-Path $flutterOutputRoot $relative))) { throw "Required current Flutter bundle item missing: $relative" }
        }
        $producedPluginDlls = @(Get-ChildItem -LiteralPath $flutterOutputRoot -File -Filter '*_plugin.dll' | ForEach-Object Name | Sort-Object)
        if (Compare-Object ($acceptedPlugins | Sort-Object) $producedPluginDlls) {
            throw "Generated bundle contains a stale or missing plugin DLL. Produced: $($producedPluginDlls -join ', ')"
        }
        $spend = Join-Path $flutterOutputRoot 'data\flutter_assets\assets\sapling-spend.params'
        $output = Join-Path $flutterOutputRoot 'data\flutter_assets\assets\sapling-output.params'
        if ((Get-FileHash $spend -Algorithm SHA256).Hash.ToLowerInvariant() -ne '8e48ffd23abb3a5fd9c5589204f32d9c31285a04b78096ba40a79b75677efc13') { throw 'Staged-asset source Sapling spend parameter hash mismatch.' }
        if ((Get-FileHash $output -Algorithm SHA256).Hash.ToLowerInvariant() -ne '2f0ebbcbb9bb0bcffe95a397e7eba89c29eb4dde6191c339db88570e3f3fb0e4') { throw 'Staged-asset source Sapling output parameter hash mismatch.' }
    }

    $exePe = Get-PeEvidence -Dumpbin $dumpbin -Path $exeOutput -RequireGui
    $exeVersion = (Get-Item -LiteralPath $exeOutput).VersionInfo
    if ($exeVersion.ProductName -ne 'BUCK Wallet') { throw "Unexpected ProductName: $($exeVersion.ProductName)" }
    if ($exeVersion.OriginalFilename -ne 'buck-wallet.exe') { throw "Unexpected OriginalFilename: $($exeVersion.OriginalFilename)" }
    if ($exeVersion.FileVersion -notmatch '^1\.14\.2' -or $exeVersion.ProductVersion -notmatch '^1\.14\.2') {
        $script:Warnings.Add("Windows numeric version mapping requires human decision: FileVersion='$($exeVersion.FileVersion)', ProductVersion='$($exeVersion.ProductVersion)', wallet='$($script:Version)'.")
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $exeOutput

    Write-Stage 'STAGING' 'Create a fresh same-filesystem temporary release and copy only current outputs' {
        $versionRoot = Split-Path -Parent $script:FinalDirectory
        [void](New-Item -ItemType Directory -Path $versionRoot -Force)
        $script:StageDirectory = Join-Path $versionRoot ('.BUCK-Wallet.' + [Guid]::NewGuid().ToString('N') + '.tmp')
        [void](Assert-DirectChildBoundary $script:StageDirectory $versionRoot)
        if (Test-Path -LiteralPath $script:StageDirectory) { throw 'Generated temporary staging path unexpectedly exists.' }
        [void](New-Item -ItemType Directory -Path $script:StageDirectory)
        Get-ChildItem -LiteralPath $flutterOutputRoot -Force | Copy-Item -Destination $script:StageDirectory -Recurse
        Copy-Item -LiteralPath $nativeOutput -Destination (Join-Path $script:StageDirectory 'warp_api_ffi.dll')
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'LICENSE.md') -Destination (Join-Path $script:StageDirectory 'LICENSE.md')

        $sourcePes = @($nativeOutput) + @(Get-ChildItem -LiteralPath $flutterOutputRoot -Recurse -File | Where-Object { $_.Extension -in @('.exe','.dll') } | ForEach-Object FullName)
        $sourceImports = @($sourcePes | ForEach-Object { (Get-PeEvidence -Dumpbin $dumpbin -Path $_).imports } | Sort-Object -Unique)
        $crtNames = @('msvcp140.dll','vcruntime140.dll','vcruntime140_1.dll')
        foreach ($crt in $crtNames) {
            if ($sourceImports -contains $crt -and -not (Test-Path -LiteralPath (Join-Path $script:StageDirectory $crt))) {
                $supported = Join-Path $script:RepoRoot "runtime\$crt"
                if (-not (Test-Path -LiteralPath $supported -PathType Leaf)) { throw "Required app-local CRT is unavailable from repository support: $crt" }
                Copy-Item -LiteralPath $supported -Destination (Join-Path $script:StageDirectory $crt)
            }
        }
    }

    $dependencyResults = [Collections.Generic.List[object]]::new()
    Write-Stage 'STAGED-VERIFY' 'Validate staged hash equality, naming, PE import closure and complete payload' {
        if (Get-ChildItem -LiteralPath $script:StageDirectory -Recurse -File | Where-Object { $_.Name -match '(?i)ywallet' }) { throw 'Legacy YWallet/ywallet product filename found in final staging.' }
        $duplicateParams = @(Get-ChildItem -LiteralPath $script:StageDirectory -Recurse -File | Where-Object { $_.Name -in @('sapling-spend.params','sapling-output.params') })
        if ($duplicateParams.Count -ne 2) { throw "Sapling parameter release copy count must be exactly 2, observed $($duplicateParams.Count)." }
        $stagedNative = Join-Path $script:StageDirectory 'warp_api_ffi.dll'
        $stagedExe = Join-Path $script:StageDirectory 'buck-wallet.exe'
        if ((Get-FileHash $stagedNative -Algorithm SHA256).Hash -ne (Get-FileHash $nativeOutput -Algorithm SHA256).Hash) { throw 'Staged native DLL hash differs from current native build output.' }
        if ((Get-FileHash $stagedExe -Algorithm SHA256).Hash -ne (Get-FileHash $exeOutput -Algorithm SHA256).Hash) { throw 'Staged executable hash differs from current Flutter build output.' }

        $stagedFiles = @(Get-ChildItem -LiteralPath $script:StageDirectory -Recurse -File)
        $stagedNames = @{}; foreach ($file in $stagedFiles) { $stagedNames[$file.Name.ToLowerInvariant()] = $true }
        foreach ($pe in @($stagedFiles | Where-Object { $_.Extension -in @('.exe','.dll') })) {
            $evidence = Get-PeEvidence -Dumpbin $dumpbin -Path $pe.FullName
            foreach ($import in $evidence.imports) {
                $lower = $import.ToLowerInvariant()
                $classification = if ($stagedNames.ContainsKey($lower)) { 'STAGED APP-LOCAL' }
                    elseif ($lower -match '^(api-ms-|ext-ms-)') { 'WINDOWS SYSTEM' }
                    elseif (Test-Path -LiteralPath (Join-Path $env:SystemRoot "System32\$import") -PathType Leaf) { 'WINDOWS SYSTEM' }
                    else { 'UNPROVEN / MISSING' }
                $dependencyResults.Add([pscustomobject][ordered]@{ binary = $pe.Name; dependency = $import; classification = $classification })
                if ($classification -eq 'UNPROVEN / MISSING') { throw "Missing non-system staged dependency '$import' required by '$($pe.Name)'." }
            }
        }
        $script:VerificationStatus = 'PASS'
    }

    Write-Stage 'SOURCE-POST-CHECK' 'Reconfirm immutable source SHA and clean tracked source before finalization' {
        $postSha = (Invoke-Git @('rev-parse','HEAD')).Trim()
        if ($postSha -ne $script:ReleaseSourceSha) { throw "Source SHA drifted during build: $postSha" }
        $postStatus = Invoke-Git @('-c','core.optionalLocks=false','status','--porcelain=v1','-uall')
        if ($postStatus) { throw "Source worktree changed during build: $postStatus" }
    }

    Write-Stage 'MANIFEST' 'Hash every payload file except the non-self-hashing manifest and finalize build evidence' {
        $payloadFiles = @(Get-ChildItem -LiteralPath $script:StageDirectory -Recurse -File | Sort-Object FullName)
        $script:Artifacts = @($payloadFiles | ForEach-Object { Get-FileEvidence $_.FullName $script:StageDirectory })
        $submodules = @()
        $indexRecords = (Invoke-Git @('ls-files','--stage')) -split "`r?`n"
        foreach ($line in $indexRecords) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if ($line -match '^160000 ([0-9a-f]{40}) ([0-3])\t(.+)$') {
                $submodules += [pscustomobject]@{ path=$Matches[3]; sha=$Matches[1] }
            } elseif ($line -match '^160000(?:\s|$)') {
                throw "Malformed gitlink index record: $line"
            }
        }
        $manifest = [pscustomobject][ordered]@{
            schema_version = 1
            created_utc = [DateTime]::UtcNow.ToString('o')
            repository = [string]$baseline.repository
            canonical_branch = [string]$baseline.canonical_branch
            source_sha = $script:ReleaseSourceSha
            wallet_version = [pscustomobject]@{ full=$script:Version; name=($script:Version -split '\+')[0]; build_number=($script:Version -split '\+')[1] }
            flutter_identity = $baseline.flutter
            dart_identity = $baseline.dart
            rust_identity = $baseline.rust
            cargo_identity = [pscustomobject]@{ executable=(Split-Path -Leaf $cargoExe); preflight_observed=$cargoIdentity.observed }
            visual_studio_identity = [pscustomobject]@{ product=$baseline.windows_toolchain.product; product_version=$baseline.windows_toolchain.product_version; installation_version=$baseline.windows_toolchain.installation_version }
            msvc_identity = [pscustomobject]@{ msvc=$baseline.windows_toolchain.msvc; cl=$baseline.windows_toolchain.cl; toolset=$baseline.windows_toolchain.toolset }
            windows_sdk_identity = $baseline.windows_toolchain.windows_sdk
            cmake_identity = $baseline.cmake
            native_features = @('dart_ffi','sqlcipher')
            build_time_sapling_parameters = $script:BuildParameters
            submodule_shas = $submodules
            preflight = [pscustomobject]@{ exit_code=$script:PreflightExit; summary=$script:Preflight.summary; warnings=@($script:Preflight.checks | Where-Object classification -in @('WARNING','SKIPPED') | ForEach-Object { [pscustomobject]@{ id=$_.id; classification=$_.classification } }); environmental_blockers=@($script:EnvironmentalBlockers) }
            avast = [pscustomobject]@{ blocker_detected=($script:EnvironmentalBlockers -contains 'AVAST_CARGO_EVOGEN'); operator_acknowledged=[bool]$AcknowledgeKnownAvastBlocker; vendor_confirmation='PENDING'; cargo_workspace_check='BLOCKED BY LOCAL AV / ENDPOINT ENVIRONMENT'; cargo_workspace_test='NOT RUN AFTER CHECK BLOCKED' }
            build = [pscustomobject]@{ native_status=$script:NativeStatus; flutter_status=$script:FlutterStatus; verification_status=$script:VerificationStatus; architecture='x64 / 8664'; mode='release' }
            artifacts = $script:Artifacts
            artifact_coverage_policy = 'All payload files are hashed except BUCK-Wallet-build-manifest.json; the manifest does not self-hash.'
            dependencies = @($dependencyResults)
            native_dll = $script:NativeEvidence
            windows_executable = [pscustomobject]@{ machine=$exePe.machine; subsystem=$exePe.subsystem; product_name=$exeVersion.ProductName; original_filename=$exeVersion.OriginalFilename; file_version=$exeVersion.FileVersion; product_version=$exeVersion.ProductVersion; source_entry_point='wWinMain'; cmake_target='WIN32'; icon_resource='present'; signing_status=[string]$signature.Status }
            sapling_parameters = @([pscustomobject]@{relative_path='data\flutter_assets\assets\sapling-spend.params';sha256='8e48ffd23abb3a5fd9c5589204f32d9c31285a04b78096ba40a79b75677efc13'},[pscustomobject]@{relative_path='data\flutter_assets\assets\sapling-output.params';sha256='2f0ebbcbb9bb0bcffe95a397e7eba89c29eb4dde6191c339db88570e3f3fb0e4'})
            source_post_check = [pscustomobject]@{ sha=$script:ReleaseSourceSha; clean=$true }
            warnings = @($script:Warnings) + @('Core compatibility: PENDING HUMAN APPROVAL','Legal sufficiency: PROVISIONAL')
            smoke_test_status = 'NOT_PERFORMED_IN_P5A'
            signing_status = $(if ($signature.Status -eq 'NotSigned') { 'UNSIGNED / NOT_PERFORMED_IN_P5A' } else { "$($signature.Status) / NOT_PERFORMED_IN_P5A" })
            installer_status = 'NOT_BUILT_IN_P5A'
        }
        $manifestTempPath = Join-Path $script:StageDirectory 'BUCK-Wallet-build-manifest.json'
        [IO.File]::WriteAllText($manifestTempPath, ($manifest | ConvertTo-Json -Depth 16), [Text.UTF8Encoding]::new($false))
    }

    Write-Stage 'PROMOTION' 'Atomically rename validated temporary staging to the final release directory' {
        if (Test-Path -LiteralPath $script:FinalDirectory) { throw 'Final release destination appeared before promotion; refusing replacement.' }
        Move-Item -LiteralPath $script:StageDirectory -Destination $script:FinalDirectory
        $script:StageDirectory = $null
        if (-not (Test-Path -LiteralPath $script:ManifestPath -PathType Leaf)) { throw 'Promoted manifest is missing.' }
    }

    $script:Started.Stop()
    Write-MachineResult 'RELEASE READY FOR RUNTIME VALIDATION'
    Write-Host 'RELEASE READY FOR RUNTIME VALIDATION'
    Write-Host "Release: dist\windows\$($script:Version)\BUCK-Wallet"
    Write-Host "Manifest: dist\windows\$($script:Version)\BUCK-Wallet\BUCK-Wallet-build-manifest.json"
    Write-Host "Result: dist\windows\$($script:Version)\BUCK-Wallet-build-result.json"
    exit 0
} catch {
    $script:FailureMessage = $_.Exception.Message
    $script:VerificationStatus = if ($script:VerificationStatus -eq 'PASS') { 'PASS' } else { 'FAIL' }
    $script:Started.Stop()
    Write-MachineResult 'FAILED'
    Write-Error $script:FailureMessage
    exit 1
}
