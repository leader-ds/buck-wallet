$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$violations = [System.Collections.Generic.List[string]]::new()

function Test-ForbiddenPattern {
    param(
        [string]$Label,
        [string]$Pattern,
        [string[]]$Paths,
        [string[]]$Globs = @()
    )

    $arguments = @('-n', '--no-heading', $Pattern)
    foreach ($glob in $Globs) {
        $arguments += @('--glob', $glob)
    }
    $arguments += $Paths

    $matches = & rg @arguments 2>$null
    if ($LASTEXITCODE -eq 0) {
        $violations.Add("${Label}:`n$($matches -join "`n")")
    } elseif ($LASTEXITCODE -ne 1) {
        throw "Identity scan command failed for $Label (rg exit $LASTEXITCODE)."
    }
}

Push-Location $repositoryRoot
try {
    $packageName = Select-String -LiteralPath 'pubspec.yaml' -Pattern '^name:\s*(\S+)\s*$'
    if ($packageName.Matches.Groups[1].Value -ne 'buck_wallet') {
        $violations.Add('pubspec.yaml package name is not buck_wallet.')
    }

    Test-ForbiddenPattern 'legacy Dart package import' 'package:[Yy][Ww]allet/' @('lib', 'test') @('*.dart')
    Test-ForbiddenPattern 'legacy localization key' 'welcomeToYwallet' @('lib/l10n', 'lib/generated/intl', 'lib/pages') @('*.arb', '*.dart')
    Test-ForbiddenPattern 'legacy backup filename' 'YWallet\.age' @('lib', 'test') @('*.dart')
    Test-ForbiddenPattern 'visible legacy product branding' 'YWallet(Test)?' @('lib', 'README.md') @('*.dart', '*.arb', '*.md')

    if ($violations.Count -gt 0) {
        $violations | ForEach-Object { Write-Error $_ }
        exit 1
    }

    Write-Output '01F-ID-1 identity scan PASS'
    Write-Output 'Excluded by design: native/FFI, Windows executable/resources, MSIX, platform package IDs, Flatpak/upstream references, and historical provenance.'
} finally {
    Pop-Location
}
