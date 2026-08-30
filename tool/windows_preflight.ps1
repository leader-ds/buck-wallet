[CmdletBinding()]
param(
    [string]$Mode = 'DeveloperPreflight',
    [string]$NetworkMode = 'Offline',
    [string]$OutputFormat = 'Json',
    [string]$JsonOutputPath,
    [string]$FlutterRoot,
    [string]$PerlPath,
    [string]$ExpectedReleaseSha,
    [switch]$Quick,
    [string]$BaselinePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Checks = [System.Collections.Generic.List[object]]::new()
$script:InternalError = $false
$script:BaselineSchema = 2
$script:RepoRoot = $null
$script:Baseline = $null

function Add-Check {
    param([string]$Id, [string]$Description, $Expected, $Observed,
          [ValidateSet('PASS','WARNING','BLOCKED','UNPROVEN','ENVIRONMENTAL_BLOCKER','SKIPPED')][string]$Classification,
          [bool]$Required, [string]$Remediation, [string]$EvidenceSource, [long]$DurationMs = 0)
    $script:Checks.Add([pscustomobject][ordered]@{
        id=$Id; description=$Description; expected=$Expected; observed=$Observed
        classification=$Classification; required=$Required; remediation=$Remediation
        evidence_source=$EvidenceSource; duration_ms=$DurationMs
    })
}

function Invoke-Captured {
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$Arguments = @(), [string]$WorkingDirectory)
    $old = (Get-Location).Path; $oldPreference=$ErrorActionPreference
    try {
        if ($WorkingDirectory) { Set-Location -LiteralPath $WorkingDirectory }
        $ErrorActionPreference='Continue'
        $lines = @(& $FilePath @Arguments 2>&1 | ForEach-Object { $_.ToString() })
        [pscustomobject]@{ ExitCode=$LASTEXITCODE; Output=($lines -join "`n").Trim() }
    } catch {
        [pscustomobject]@{ ExitCode=-1; Output=$_.Exception.Message }
    } finally { $ErrorActionPreference=$oldPreference; Set-Location -LiteralPath $old }
}

function Test-Sha([object]$Value, [int]$Length) {
    $Value -is [string] -and $Value -match ('\A[0-9a-fA-F]{' + $Length + '}\z')
}

function Resolve-SafePath {
    param([string]$Path, [bool]$MustExist=$true)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if ($MustExist -and -not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path } catch { return $null }
}

function Test-Reparse([string]$Path) {
    try { return [bool]((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) } catch { return $false }
}

function Add-HashCheck {
    param($Item, [string]$Prefix, [bool]$Required=$true)
    $sw=[Diagnostics.Stopwatch]::StartNew(); $full=Join-Path $script:RepoRoot ([string]$Item.path)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        $sw.Stop(); Add-Check "${Prefix}_MISSING" "Required file exists and matches SHA-256" $Item.sha256 'missing' 'BLOCKED' $Required 'Restore the reviewed tracked file.' $Item.path $sw.ElapsedMilliseconds; return
    }
    if ($Mode -eq 'ReleasePreflight' -and (Test-Reparse $full)) {
        $sw.Stop(); Add-Check "${Prefix}_REPARSE" 'Release input is not a reparse point' 'regular file' 'reparse point' 'BLOCKED' $Required 'Use a regular repository file.' $Item.path $sw.ElapsedMilliseconds; return
    }
    $actual=(Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant(); $sw.Stop()
    $class=if($actual -eq $Item.sha256){'PASS'}else{'BLOCKED'}
    Add-Check "${Prefix}_HASH" 'File SHA-256 matches reviewed baseline' $Item.sha256 $actual $class $Required 'Restore the exact reviewed file or review and update the baseline together.' $Item.path $sw.ElapsedMilliseconds
}

function Assert-Baseline {
    $required=@('schema_version','policy_revision','repository','canonical_branch','minimum_baseline_sha','authority','human_manifests','history_anchors','flutter','dart','pub','rust','windows_toolchain','cmake','perl','parameters','submodules','native_runtime','windows_runner','core_compatibility','known_environmental_blockers')
    foreach($name in $required){ if(-not $script:Baseline.PSObject.Properties[$name]){throw "Baseline missing field: $name"} }
    if($script:Baseline.schema_version -ne $script:BaselineSchema){throw "Unsupported schema_version: $($script:Baseline.schema_version)"}
    if(-not (Test-Sha $script:Baseline.minimum_baseline_sha 40)){throw 'Invalid minimum_baseline_sha'}
    $seen=@{}
    foreach($m in @($script:Baseline.human_manifests)){
        if($seen.ContainsKey([string]$m.path)){throw "Duplicate manifest path: $($m.path)"};$seen[$m.path]=$true
        if(-not (Test-Sha $m.sha256 64)){throw "Invalid manifest hash: $($m.path)"}
    }
    foreach($a in @($script:Baseline.history_anchors)){if(-not(Test-Sha $a 40)){throw "Invalid history anchor: $a"}}
    $seen=@{};foreach($s in @($script:Baseline.submodules.gitlinks)){if($seen.ContainsKey([string]$s.path)){throw "Duplicate gitlink: $($s.path)"};$seen[$s.path]=$true;if(-not(Test-Sha $s.sha 40)){throw "Invalid gitlink SHA: $($s.path)"}}
    foreach($f in @($script:Baseline.pub.files)+@($script:Baseline.parameters.files)){if(-not(Test-Sha $f.sha256 64)){throw "Invalid SHA-256: $($f.path)"}}
    if(@($script:Baseline.human_manifests).Count -ne 2){throw 'Exactly two human manifests are required'}
    if(@($script:Baseline.submodules.gitlinks).Count -ne 6){throw 'Exactly six direct gitlinks are required'}
}

function Test-GitState {
    $git=(Get-Command git -ErrorAction SilentlyContinue)
    if(-not $git){Add-Check 'GIT_AVAILABLE' 'Git is available' 'git' 'missing' 'BLOCKED' $true 'Install the reviewed Git for Windows tool.' 'PATH';return $null}
    $head=Invoke-Captured $git.Source @('rev-parse','HEAD') $script:RepoRoot
    if($head.ExitCode -ne 0 -or -not(Test-Sha $head.Output 40)){Add-Check 'GIT_HEAD' 'Read repository HEAD' '40-hex SHA' $head.Output 'UNPROVEN' $true 'Run inside a valid checkout.' 'git rev-parse HEAD';return $null}
    $branch=(Invoke-Captured $git.Source @('branch','--show-current') $script:RepoRoot).Output
    $ancestor=Invoke-Captured $git.Source @('merge-base','--is-ancestor',$script:Baseline.minimum_baseline_sha,$head.Output) $script:RepoRoot
    Add-Check 'SOURCE_BASELINE' 'HEAD descends from accepted minimum source baseline' "descendant of $($script:Baseline.minimum_baseline_sha)" $head.Output $(if($ancestor.ExitCode -eq 0){'PASS'}else{'BLOCKED'}) $true 'Use the accepted source lineage.' 'git merge-base --is-ancestor'
    if($Mode -eq 'ReleasePreflight'){
        Add-Check 'SOURCE_IDENTITY' 'Release HEAD exactly matches caller-supplied reviewed source identity' $ExpectedReleaseSha $head.Output $(if($head.Output -eq $ExpectedReleaseSha){'PASS'}else{'BLOCKED'}) $true 'Supply the exact reviewed release commit with -ExpectedReleaseSha.' 'parameter / git rev-parse HEAD'
    }
    if($branch -eq $script:Baseline.canonical_branch){Add-Check 'CANONICAL_BRANCH_LINEAGE' 'Checked-out canonical branch descends from accepted minimum source baseline' "descendant of $($script:Baseline.minimum_baseline_sha)" $head.Output $(if($ancestor.ExitCode -eq 0){'PASS'}else{'BLOCKED'}) $true 'Stop and review canonical branch lineage.' 'git branch --show-current / merge-base'}
    $status=(Invoke-Captured $git.Source @('-c','core.optionalLocks=false','status','--porcelain=v1','-uall') $script:RepoRoot).Output
    if([string]::IsNullOrEmpty($status)){Add-Check 'SUPERPROJECT_CLEAN' 'Superproject working tree state' 'clean' 'clean' 'PASS' $true '' 'git status --porcelain=v1'}
    else {
        $protected='(^|\s)(docs/security/|pubspec\.(yaml|lock)$|packages/warp_api_ffi/pubspec\.(yaml|lock)$|assets/sapling-|native/zcash-sync|native/zcash-params|librustzcash|orchard|native/zcash-vote|misc/flathub)'
        $dirtyProtected=@($status -split "`n" | Where-Object {$_ -match $protected})
        $c=if($Mode -eq 'ReleasePreflight' -or $dirtyProtected.Count -gt 0){'BLOCKED'}else{'WARNING'}
        Add-Check 'SUPERPROJECT_CLEAN' 'Superproject working tree state' $(if($Mode -eq 'ReleasePreflight'){'clean'}else{'protected inputs clean'}) $status $c $true 'Remove unrelated dirt, or restore reviewed protected inputs. ReleasePreflight requires a fully clean tree.' 'git status --porcelain=v1'
    }
    foreach($a in @($script:Baseline.history_anchors)){$r=Invoke-Captured $git.Source @('merge-base','--is-ancestor',$a,$head.Output) $script:RepoRoot;Add-Check "HISTORY_$($a.Substring(0,8).ToUpperInvariant())" 'Accepted history anchor is an ancestor' $a $(if($r.ExitCode -eq 0){'ancestor'}else{'not ancestor'}) $(if($r.ExitCode -eq 0){'PASS'}else{'BLOCKED'}) $true 'Use an approved history lineage.' 'git merge-base --is-ancestor'}
    [pscustomobject]@{Git=$git.Source;Head=$head.Output;Branch=$branch}
}

function Get-NestedGitlinkState {
    param([string]$Git, [string]$Repository, [string]$Label)
    $problems=[System.Collections.Generic.List[string]]::new()
    $index=Invoke-Captured $Git @('-C',$Repository,'ls-files','--stage')
    if($index.ExitCode -ne 0){$problems.Add("$Label index unreadable: $($index.Output)");return $problems}
    foreach($line in @($index.Output -split "`n"|Where-Object{$_ -match '^160000\s+([0-9a-f]{40})\s+\d+\s+(.+)$'})){
        $null=$line -match '^160000\s+([0-9a-f]{40})\s+\d+\s+(.+)$';$expected=$Matches[1];$relative=$Matches[2];$child=Join-Path $Repository $relative;$childLabel="$Label/$relative"
        $inside=Invoke-Captured $Git @('-C',$child,'rev-parse','--is-inside-work-tree')
        if($inside.ExitCode -ne 0 -or $inside.Output -ne 'true'){$problems.Add("$childLabel uninitialized");continue}
        $head=(Invoke-Captured $Git @('-C',$child,'rev-parse','HEAD')).Output;$status=(Invoke-Captured $Git @('-C',$child,'status','--porcelain=v1','-uall')).Output
        if($head -ne $expected){$problems.Add("$childLabel HEAD=$head expected=$expected")};if($status){$problems.Add("$childLabel dirty: $status")}
        foreach($p in @(Get-NestedGitlinkState $Git $child $childLabel)){$problems.Add($p)}
    }
    $problems
}

function Test-Submodules($GitState) {
    foreach($s in @($script:Baseline.submodules.gitlinks)){
        $actual=(Invoke-Captured $GitState.Git @('ls-tree',$script:Baseline.minimum_baseline_sha,'--',$s.path) $script:RepoRoot).Output
        $parts=$actual -split '\s+'; $treeSha=if($parts.Count -ge 3){$parts[2]}else{''}
        Add-Check "GITLINK_$($s.path.Replace('/','_').ToUpperInvariant())" 'Baseline and superproject gitlink match contract' $s.sha $treeSha $(if($treeSha -eq $s.sha){'PASS'}else{'BLOCKED'}) $true $script:Baseline.submodules.remediation 'git ls-tree'
        $dir=Join-Path $script:RepoRoot ([string]$s.path); $inside=Invoke-Captured $GitState.Git @('-C',$dir,'rev-parse','--is-inside-work-tree')
        if($inside.ExitCode -ne 0 -or $inside.Output -ne 'true'){Add-Check "SUBMODULE_$($s.path.Replace('/','_').ToUpperInvariant())" 'Submodule initialized at exact clean SHA' $s.sha 'uninitialized' 'BLOCKED' $true $script:Baseline.submodules.remediation $s.path;continue}
        $h=(Invoke-Captured $GitState.Git @('-C',$dir,'rev-parse','HEAD')).Output;$st=(Invoke-Captured $GitState.Git @('-C',$dir,'status','--porcelain=v1','-uall')).Output;$nested=@(Get-NestedGitlinkState $GitState.Git $dir $s.path)
        $ok=($h -eq $s.sha -and [string]::IsNullOrEmpty($st) -and $nested.Count -eq 0)
        Add-Check "SUBMODULE_$($s.path.Replace('/','_').ToUpperInvariant())" 'Submodule initialized at exact clean SHA; nested gitlinks inspected directly' $s.sha "HEAD=$h; clean=$([string]::IsNullOrEmpty($st)); nested_problems=$($nested -join '; ')" $(if($ok){'PASS'}else{'BLOCKED'}) $true $script:Baseline.submodules.remediation $s.path
    }
}

function Test-Flutter {
    $root=if($FlutterRoot){$FlutterRoot}else{$script:Baseline.flutter.preferred_local_root};$resolved=Resolve-SafePath $root
    if(-not $resolved){Add-Check 'FLUTTER_ROOT' 'Flutter root exists' $script:Baseline.flutter.version $root 'BLOCKED' $true 'Supply -FlutterRoot pointing to the exact reviewed SDK.' 'parameter/baseline';return}
    if($Mode -eq 'ReleasePreflight' -and (Test-Reparse $resolved)){Add-Check 'FLUTTER_ROOT_REPARSE' 'Flutter root is not a reparse point' 'regular directory' 'reparse point' 'BLOCKED' $true 'Use a validated non-reparse SDK root.' $resolved;return}
    $exe=Join-Path $resolved 'bin\flutter.bat';$versionFile=Join-Path $resolved 'version';$engineFile=Join-Path $resolved 'bin\internal\engine.version';$dartFile=Join-Path $resolved 'bin\cache\dart-sdk\version';$git=Get-Command git -ErrorAction SilentlyContinue
    if(-not(Test-Path -LiteralPath $exe -PathType Leaf)){Add-Check 'FLUTTER_EXECUTABLE' 'Selected Flutter executable exists as a file' $exe 'missing' 'BLOCKED' $true 'Supply -FlutterRoot pointing to the exact reviewed SDK checkout.' $exe;return}
    Add-Check 'FLUTTER_EXECUTABLE' 'Selected Flutter executable exists as a file' $exe $exe 'PASS' $true '' $exe
    if(-not(Test-Path -LiteralPath $versionFile -PathType Leaf) -or -not(Test-Path -LiteralPath $engineFile -PathType Leaf) -or -not$git){Add-Check 'FLUTTER_IDENTITY' 'Flutter identity metadata is discoverable' $script:Baseline.flutter.version 'required SDK metadata missing' 'BLOCKED' $true 'Supply the exact reviewed Flutter SDK.' $resolved;return}
    $fv=(Get-Content -LiteralPath $versionFile -Raw).Trim();$engine=(Get-Content -LiteralPath $engineFile -Raw).Trim();$framework=(Invoke-Captured $git.Source @('-C',$resolved,'rev-parse','HEAD')).Output
    $ok=($fv -eq $script:Baseline.flutter.version -and $framework -eq $script:Baseline.flutter.framework_sha -and $engine -eq $script:Baseline.flutter.engine_sha);$obs="version=$fv; framework=$framework; engine=$engine"
    Add-Check 'FLUTTER_IDENTITY' 'Flutter version/framework/engine identity' "$($script:Baseline.flutter.version); $($script:Baseline.flutter.framework_sha); $($script:Baseline.flutter.engine_sha)" $obs $(if($ok){'PASS'}else{'BLOCKED'}) $true 'Select the exact reviewed Flutter SDK.' 'flutter --version --machine'
    $sdkStatus=Invoke-Captured $git.Source @('-c','core.optionalLocks=false','-C',$resolved,'status','--porcelain=v1','-uall')
    $sdkClean=$sdkStatus.ExitCode -eq 0 -and [string]::IsNullOrEmpty($sdkStatus.Output)
    Add-Check 'FLUTTER_SDK_GIT_CLEAN' 'Selected Flutter SDK Git checkout has no tracked modifications or untracked files' 'clean (tracked and untracked)' $(if($sdkClean){'clean'}else{$sdkStatus.Output}) $(if($sdkClean){'PASS'}else{'BLOCKED'}) $true 'Review the selected SDK checkout; do not clean or reset it automatically.' 'git status --porcelain=v1 -uall'
    $dart=if(Test-Path -LiteralPath $dartFile){(Get-Content -LiteralPath $dartFile -Raw).Trim()}else{'missing'}
    Add-Check 'DART_VERSION' 'Bundled Dart SDK version is exact' $script:Baseline.dart.version $dart $(if($dart -eq $script:Baseline.dart.version){'PASS'}else{'BLOCKED'}) $true 'Use Dart bundled with the reviewed Flutter SDK.' 'Flutter SDK dart version metadata'
    $pathFlutter=Get-Command flutter -ErrorAction SilentlyContinue;if($pathFlutter -and $pathFlutter.Source -ne $exe){Add-Check 'PATH_FLUTTER_MISMATCH' 'PATH Flutter is the selected Flutter executable' $exe $pathFlutter.Source 'WARNING' $false 'Use -FlutterRoot; PATH is diagnostic only.' 'PATH'}else{Add-Check 'PATH_FLUTTER_MISMATCH' 'PATH Flutter diagnostic' $exe $(if($pathFlutter){$pathFlutter.Source}else{'not on PATH'}) 'PASS' $false '' 'PATH'}
}

function Test-Rust {
    foreach($tool in @(@{n='rustc';v=$script:Baseline.rust.rustc_version},@{n='cargo';v=$script:Baseline.rust.cargo_version})){$cmd=Get-Command $tool.n -ErrorAction SilentlyContinue;if(-not$cmd){Add-Check "$($tool.n.ToUpperInvariant())_VERSION" "$($tool.n) version is exact" $tool.v 'missing' 'BLOCKED' $true 'Install/select the exact reviewed Rust toolchain.' 'PATH';continue};$r=Invoke-Captured $cmd.Source @('-Vv');$first=($r.Output -split "`n")[0];$ok=$r.ExitCode -eq 0 -and $first -match ("^$($tool.n) " + [regex]::Escape($tool.v) + '([ -]|$)');Add-Check "$($tool.n.ToUpperInvariant())_VERSION" "$($tool.n) version is exact" $tool.v $r.Output $(if($ok){'PASS'}else{'BLOCKED'}) $true 'Install/select the exact reviewed Rust toolchain.' "$($tool.n) -Vv";if($tool.n -eq 'rustc'){Add-Check 'RUST_HOST' 'Rust host is exact' $script:Baseline.rust.host $r.Output $(if($r.Output -match ('host:\s*'+[regex]::Escape($script:Baseline.rust.host))){'PASS'}else{'BLOCKED'}) $true 'Select the reviewed MSVC host toolchain.' 'rustc -Vv'}}
}

function Test-Perl {
    $p=if($PerlPath){$PerlPath}else{$script:Baseline.perl.preferred_local_executable};$resolved=Resolve-SafePath $p
    if(-not$resolved){Add-Check 'PERL_IDENTITY' 'Strawberry Perl identity/module' "$($script:Baseline.perl.version); $($script:Baseline.perl.architecture)" 'missing' 'BLOCKED' $true 'Supply -PerlPath for exact Strawberry Perl.' 'parameter/baseline';return}
    if($Mode -eq 'ReleasePreflight' -and (Test-Reparse $resolved)){Add-Check 'PERL_REPARSE' 'Perl executable is not a reparse point' 'regular file' 'reparse point' 'BLOCKED' $true 'Use a validated regular executable.' $resolved;return}
    $identity=Invoke-Captured $resolved @('-V:version','-V:archname');$module=Invoke-Captured $resolved @('-MLocale::Maketext::Simple','-e','1')
    $ok=$identity.ExitCode -eq 0 -and $identity.Output -match ("version='"+[regex]::Escape($script:Baseline.perl.version)+"'") -and $identity.Output -match ("archname='"+[regex]::Escape($script:Baseline.perl.architecture)+"'") -and $module.ExitCode -eq 0 -and $resolved -notmatch '\\Git\\'
    Add-Check 'PERL_IDENTITY' 'Strawberry Perl version, architecture, and required module' "$($script:Baseline.perl.version); $($script:Baseline.perl.architecture); $($script:Baseline.perl.required_module)" "identity=$($identity.Output); module_exit=$($module.ExitCode)" $(if($ok){'PASS'}else{'BLOCKED'}) $true 'Install/select exact Strawberry Perl with the required module.' 'perl fixed -V/module-load queries'
}

function Test-Toolchain {
    $vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if(-not(Test-Path -LiteralPath $vswhere)){Add-Check 'VS_DISCOVERY' 'Visual Studio discovered through vswhere' $script:Baseline.windows_toolchain.installation_version 'vswhere missing' 'BLOCKED' $true 'Install the reviewed Visual Studio 2022 workload.' 'vswhere';return}
    $r=Invoke-Captured $vswhere @('-latest','-products','*','-requires',$script:Baseline.windows_toolchain.workload,'-format','json','-utf8')
    try{$v=@($r.Output|ConvertFrom-Json)[0]}catch{$v=$null}
    if(-not$v){Add-Check 'VS_DISCOVERY' 'Visual Studio discovered through vswhere' $script:Baseline.windows_toolchain.installation_version $r.Output 'BLOCKED' $true 'Install the reviewed Desktop C++ workload.' 'vswhere';return}
    $displayVersion=if($v.catalog){$v.catalog.productDisplayVersion}else{'unknown'};$ok=$v.installationVersion -eq $script:Baseline.windows_toolchain.installation_version -and $displayVersion -eq $script:Baseline.windows_toolchain.product_version
    Add-Check 'VS_IDENTITY' 'Visual Studio product and installation versions are exact' "$($script:Baseline.windows_toolchain.product_version); $($script:Baseline.windows_toolchain.installation_version)" "$displayVersion; $($v.installationVersion)" $(if($ok){'PASS'}else{'BLOCKED'}) $true 'Use the exact reviewed Visual Studio installation.' 'vswhere metadata'
    $root=$v.installationPath;$cl=Get-ChildItem -LiteralPath (Join-Path $root 'VC\Tools\MSVC') -Directory -ErrorAction SilentlyContinue|Sort-Object Name -Descending|Select-Object -First 1
    Add-Check 'MSVC_VERSION' 'MSVC tools directory is exact' $script:Baseline.windows_toolchain.msvc $(if($cl){$cl.Name}else{'missing'}) $(if($cl -and $cl.Name -eq $script:Baseline.windows_toolchain.msvc){'PASS'}else{'BLOCKED'}) $true 'Install the exact reviewed MSVC component.' 'Visual Studio metadata'
    $clExe=if($cl){Join-Path $cl.FullName 'bin\Hostx64\x64\cl.exe'}else{''};$clVersion=if($clExe -and (Test-Path -LiteralPath $clExe)){(Get-Item -LiteralPath $clExe).VersionInfo.FileVersion}else{'missing'}
    Add-Check 'CL_VERSION' 'C/C++ compiler file version is exact' $script:Baseline.windows_toolchain.cl $clVersion $(if($clVersion -eq $script:Baseline.windows_toolchain.cl){'PASS'}else{'BLOCKED'}) $true 'Install the exact reviewed MSVC compiler.' $clExe
    $toolsetFile=Join-Path $root 'VC\Auxiliary\Build\Microsoft.VCToolsVersion.v143.default.txt';$toolsetVersion=if(Test-Path -LiteralPath $toolsetFile){(Get-Content -LiteralPath $toolsetFile -Raw).Trim()}else{'missing'}
    Add-Check 'TOOLSET_V143' 'v143 default toolset resolves to reviewed MSVC identity' $script:Baseline.windows_toolchain.msvc $toolsetVersion $(if($toolsetVersion -eq $script:Baseline.windows_toolchain.msvc){'PASS'}else{'BLOCKED'}) $true 'Install/select the reviewed v143 toolset.' $toolsetFile
    $msbuild=Join-Path $root 'MSBuild\Current\Bin\MSBuild.exe';$m=if(Test-Path -LiteralPath $msbuild){(Get-Item -LiteralPath $msbuild).VersionInfo.FileVersion}else{'missing'}
    Add-Check 'MSBUILD_VERSION' 'MSBuild file version is exact' $script:Baseline.windows_toolchain.msbuild $m $(if($m -eq $script:Baseline.windows_toolchain.msbuild){'PASS'}else{'BLOCKED'}) $true 'Use the exact reviewed MSBuild.' $msbuild
    $sdk=Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\Include\$($script:Baseline.windows_toolchain.windows_sdk)"
    Add-Check 'WINDOWS_SDK' 'Windows SDK identity is exact' $script:Baseline.windows_toolchain.windows_sdk $(if(Test-Path -LiteralPath $sdk){$script:Baseline.windows_toolchain.windows_sdk}else{'missing'}) $(if(Test-Path -LiteralPath $sdk){'PASS'}else{'BLOCKED'}) $true 'Install the exact reviewed Windows SDK.' 'Windows Kits Include'
    $cmPath=Join-Path $root 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe';$cmVersion=if(Test-Path -LiteralPath $cmPath){(Get-Item -LiteralPath $cmPath).VersionInfo.ProductVersion}else{'missing'}
    Add-Check 'CMAKE_VERSION' 'Reviewed VS-bundled CMake version is exact' $script:Baseline.cmake.version $cmVersion $(if($cmVersion -eq $script:Baseline.cmake.version){'PASS'}else{'BLOCKED'}) $true 'Install/select the exact reviewed VS CMake component.' $cmPath
    $pathCmake=Get-Command cmake -ErrorAction SilentlyContinue;if($pathCmake -and $pathCmake.Source -ne $cmPath){Add-Check 'PATH_CMAKE_MISMATCH' 'PATH CMake diagnostic' $cmPath $pathCmake.Source 'WARNING' $false 'Use the reviewed VS-bundled CMake for release work.' 'PATH'}
    $ninja=Get-Command ninja -ErrorAction SilentlyContinue;Add-Check 'NINJA_DIAGNOSTIC' 'Ninja presence is diagnostic; VS generator remains authoritative' 'optional' $(if($ninja){$ninja.Source}else{'not found'}) $(if($ninja){'PASS'}else{'SKIPPED'}) $false '' 'PATH'
}

function Test-StaticReadiness {
    $cargo=Get-Content -LiteralPath (Join-Path $script:RepoRoot 'native/zcash-sync/Cargo.toml') -Raw
    $n=$script:Baseline.native_runtime;$ok=$cargo -match ('name\s*=\s*"'+[regex]::Escape($n.package)+'"') -and $cargo -match ('name\s*=\s*"'+[regex]::Escape($n.library)+'"')
    foreach($ct in @($n.crate_types)){$ok=$ok -and $cargo -match ('"'+[regex]::Escape($ct)+'"')};foreach($f in @($n.required_features)){$ok=$ok -and $cargo -match ('(?m)^'+[regex]::Escape($f)+'\s*=')}
    Add-Check 'NATIVE_RUNTIME_STATIC' 'Native runtime Cargo manifest declares reviewed package/library/types/features' $n ($ok) $(if($ok){'PASS'}else{'BLOCKED'}) $true 'Restore the reviewed Cargo manifest; do not use build output as evidence.' 'native/zcash-sync/Cargo.toml'
    $w=$script:Baseline.windows_runner;$files=@('pubspec.yaml','windows/CMakeLists.txt','windows/runner/CMakeLists.txt','windows/runner/main.cpp','windows/runner/Runner.rc')
    $pub=Get-Content -LiteralPath (Join-Path $script:RepoRoot $files[0]) -Raw;$projectCmake=Get-Content -LiteralPath (Join-Path $script:RepoRoot $files[1]) -Raw;$runnerCmake=Get-Content -LiteralPath (Join-Path $script:RepoRoot $files[2]) -Raw;$main=Get-Content -LiteralPath (Join-Path $script:RepoRoot $files[3]) -Raw;$resource=Get-Content -LiteralPath (Join-Path $script:RepoRoot $files[4]) -Raw
    $iconRelative=([string]$w.icon -replace '^windows/runner/','' -replace '/','\\');$icon=Test-Path -LiteralPath (Join-Path $script:RepoRoot $w.icon) -PathType Leaf
    $ok=$icon -and $pub -match ('(?m)^name:\s*'+[regex]::Escape($w.project)+'\s*$') -and $pub -match ('(?m)^version:\s*'+[regex]::Escape($w.declared_version)+'\s*$') -and $projectCmake -match ('(?m)^project\('+[regex]::Escape($w.project)+'\s') -and $projectCmake -match ('(?m)^set\(BINARY_NAME\s+"'+[regex]::Escape($w.binary)+'"\)') -and $runnerCmake -match ('add_executable\(\$\{BINARY_NAME\}\s+'+[regex]::Escape($w.target_type)) -and $main -match ('\b'+[regex]::Escape($w.entry)+'\s*\(') -and $main -match ('CreateAndShow\(L"'+[regex]::Escape($w.product)+'"') -and $resource -match ('VALUE\s+"ProductName",\s*"'+[regex]::Escape($w.product)+'"') -and $resource -match ('VALUE\s+"OriginalFilename",\s*"'+[regex]::Escape($w.original_filename)+'"') -and $resource -match ('ICON\s+"'+[regex]::Escape($iconRelative)+'"')
    Add-Check 'WINDOWS_RUNNER_STATIC' 'Tracked Windows runner declarations match reviewed identity' $w $ok $(if($ok){'PASS'}else{'BLOCKED'}) $true 'Restore reviewed tracked runner configuration.' ($files -join ', ')
    Add-Check 'EXISTING_RELEASE_OUTPUT' 'Existing release output is not used for readiness' 'not inspected' 'not inspected' 'SKIPPED' $false '' 'policy'
    Add-Check 'CORE_COMPATIBILITY' 'Core compatibility approval remains pending' $script:Baseline.core_compatibility.status $script:Baseline.core_compatibility.status 'WARNING' $false 'Obtain separate human approval; this preflight does not claim compatibility.' 'baseline policy'
}

function Test-Endpoint {
    $observed=@();try{$observed+=@(Get-Service -ErrorAction Stop|Where-Object{$_.Name -match 'avast|asw' -or $_.DisplayName -match 'Avast'}|ForEach-Object{"$($_.Name):$($_.Status)"})}catch{}
    try{$observed+=@(Get-Process -ErrorAction Stop|Where-Object{$_.ProcessName -match 'avast|asw'}|ForEach-Object{$_.ProcessName})}catch{}
    if($observed.Count -gt 0){Add-Check 'AVAST_CARGO_EVOGEN' 'Known endpoint condition carried without running Cargo check/test' 'not active' ($observed -join '; ') 'ENVIRONMENTAL_BLOCKER' $true 'Resolve with endpoint vendor/administrator; do not disable controls or rerun blocked Cargo commands.' 'read-only service/process observation'}
    else{Add-Check 'AVAST_CARGO_EVOGEN' 'Known endpoint condition diagnostic' 'NOT_OBSERVED' 'NOT_OBSERVED (not proof vendor issue is gone)' 'WARNING' $false 'Obtain vendor confirmation before considering the carried condition resolved.' 'read-only service/process observation'}
}

function Write-Result {
    param([string]$Head='unknown')
    $exit=if($script:InternalError){2}elseif(@($script:Checks|Where-Object{$_.classification -eq 'BLOCKED' -or ($_.classification -eq 'UNPROVEN' -and $_.required)}).Count){1}elseif(@($script:Checks|Where-Object{$_.classification -eq 'ENVIRONMENTAL_BLOCKER'}).Count){3}else{0}
    $warnings=@($script:Checks|Where-Object{$_.classification -in @('WARNING','SKIPPED')}).Count
    $state=if($exit -eq 3){'ENVIRONMENTALLY BLOCKED'}elseif($exit -in 1,2){'NOT READY'}elseif($warnings){'READY WITH WARNINGS'}else{'READY'}
    $summary=[ordered]@{};foreach($c in @('PASS','WARNING','BLOCKED','UNPROVEN','ENVIRONMENTAL_BLOCKER','SKIPPED')){$summary[$c]=@($script:Checks|Where-Object classification -eq $c).Count};$summary['state']=$state
    $obj=[pscustomobject][ordered]@{schema_version=1;timestamp_utc=[DateTime]::UtcNow.ToString('o');repository=$(if($script:Baseline){$script:Baseline.repository}else{'unknown'});accepted_minimum_baseline=$(if($script:Baseline){$script:Baseline.minimum_baseline_sha}else{'unknown'});expected_release_source=$(if($Mode -eq 'ReleasePreflight'){$ExpectedReleaseSha}else{$null});observed_head=$Head;mode=$Mode;network_mode=$NetworkMode;checks=$script:Checks;summary=$summary;exit_code=$exit}
    $json=$obj|ConvertTo-Json -Depth 12
    if($JsonOutputPath){$target=[IO.Path]::GetFullPath($JsonOutputPath);[IO.File]::WriteAllText($target,$json,[Text.UTF8Encoding]::new($false))}
    if($OutputFormat -eq 'Json'){$json}else{foreach($c in $script:Checks){$label=if($c.classification -eq 'ENVIRONMENTAL_BLOCKER'){'ENV'}else{$c.classification};"[{0,-7}] {1}" -f $label,$c.id;if($c.classification -ne 'PASS' -and $c.remediation){"          Remediation: $($c.remediation)"}};"PREFLIGHT RESULT: $state"}
    exit $exit
}

$observedHead='unknown'
try {
    if($Mode -notin @('DeveloperPreflight','ReleasePreflight')){throw "Invalid Mode: $Mode"}
    if($NetworkMode -notin @('Offline','Online')){throw "Invalid NetworkMode: $NetworkMode"}
    if($OutputFormat -notin @('Text','Json')){throw "Invalid OutputFormat: $OutputFormat"}
    if($Quick -and $Mode -eq 'ReleasePreflight'){throw 'ReleasePreflight + Quick is an invalid invocation; release always requires full verification.'}
    if($Mode -eq 'ReleasePreflight' -and -not(Test-Sha $ExpectedReleaseSha 40)){throw 'ReleasePreflight requires -ExpectedReleaseSha with an exact 40-hex reviewed release commit.'}
    $scriptPath=$MyInvocation.MyCommand.Path;$scriptDir=Split-Path -Parent $scriptPath
    if(-not$BaselinePath){$BaselinePath=Join-Path $scriptDir 'windows_preflight.baseline.json'}
    $baselineResolved=Resolve-SafePath $BaselinePath;if(-not$baselineResolved){throw "Baseline JSON not found: $BaselinePath"}
    $script:Baseline=Get-Content -LiteralPath $baselineResolved -Raw|ConvertFrom-Json
    Assert-Baseline
    $script:RepoRoot=(Invoke-Captured (Get-Command git).Source @('-C',$scriptDir,'rev-parse','--show-toplevel')).Output
    if(-not(Test-Path -LiteralPath $script:RepoRoot -PathType Container)){throw 'Unable to locate repository root'}
    if($Mode -eq 'ReleasePreflight' -and (Test-Reparse $script:RepoRoot)){Add-Check 'REPOSITORY_ROOT_REPARSE' 'Repository root is not a reparse point' 'regular directory' 'reparse point' 'BLOCKED' $true 'Use a validated regular checkout.' $script:RepoRoot}
    $g=Test-GitState;if($g){$observedHead=$g.Head}
    foreach($m in @($script:Baseline.human_manifests)){Add-HashCheck $m 'HUMAN_MANIFEST'}
    foreach($f in @($script:Baseline.pub.files)){Add-HashCheck $f ('PUB_'+(([string]$f.path)-replace '[^A-Za-z0-9]','_').ToUpperInvariant())}
    foreach($f in @($script:Baseline.parameters.files)){if($Quick){Add-Check ('PARAM_'+(([string]$f.path)-replace '[^A-Za-z0-9]','_').ToUpperInvariant()) 'Large parameter hash skipped in Developer Quick mode' $f.sha256 'skipped' 'UNPROVEN' $true 'Run full DeveloperPreflight.' $f.path}else{Add-HashCheck $f ('PARAM_'+(([string]$f.path)-replace '[^A-Za-z0-9]','_').ToUpperInvariant())}}
    Test-Flutter;Test-Rust;Test-Toolchain;Test-Perl
    if($g){if($Quick){Add-Check 'SUBMODULE_FULL' 'Recursive submodule verification skipped in Developer Quick mode' 'full verification' 'skipped' 'UNPROVEN' $true 'Run full DeveloperPreflight.' 'policy'}else{Test-Submodules $g}}
    Test-StaticReadiness;Test-Endpoint
    if($NetworkMode -eq 'Online' -and $g){$remote=Invoke-Captured $g.Git @('ls-remote','--heads','origin',$script:Baseline.canonical_branch) $script:RepoRoot;if($remote.ExitCode -eq 0){$sha=($remote.Output -split '\s+')[0];Add-Check 'REMOTE_CANONICAL' 'Live remote canonical observed without ref update' $script:Baseline.minimum_baseline_sha $sha $(if($sha -eq $script:Baseline.minimum_baseline_sha){'PASS'}else{'BLOCKED'}) $true 'Stop for canonical drift.' 'git ls-remote'}else{Add-Check 'REMOTE_CANONICAL' 'Optional live remote observation' $script:Baseline.minimum_baseline_sha $remote.Output 'WARNING' $false 'Retry Online mode when network is available.' 'git ls-remote'}}else{Add-Check 'REMOTE_CANONICAL' 'Network probe disabled by default' 'offline' 'not requested' 'SKIPPED' $false '' 'NetworkMode Offline'}
} catch {
    $script:InternalError=$true;Add-Check 'PREFLIGHT_INTERNAL' 'Preflight invocation and internal execution' 'valid invocation and complete execution' $_.Exception.Message 'UNPROVEN' $true 'Correct the invocation or baseline/script defect.' 'preflight runtime'
}
Write-Result $observedHead
