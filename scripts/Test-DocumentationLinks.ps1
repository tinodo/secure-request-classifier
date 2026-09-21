#Requires -Version 7.0

<#
.SYNOPSIS
    Checks that every internal link in the documentation points at something that exists.

.DESCRIPTION
    Documentation rots silently. A heading gets reworded, and every link to its anchor keeps
    rendering as a link while quietly landing at the top of the page instead -- which reads as the
    reader's mistake rather than the document's. Renaming a file breaks links the same way.

    This repository already had one: docs/troubleshooting.md linked to
    limitations.md#1-the-canvas-app-msapp-cannot-be-built-from-source-in-ci long after that heading
    had become "1. There is no canvas app, and one cannot be built in CI".

    So this checks three things across every markdown file:

      * relative links resolve to a file that exists;
      * anchors, whether in the same file or another, match a heading that exists;
      * links to repository paths -- scripts, workflows, infrastructure -- resolve to real files.

    External http(s) links are not fetched. This must work offline and in CI without reaching the
    network, and a broken external link is somebody else's outage as often as it is our error.

.PARAMETER RepositoryRoot
    Root of the repository. Defaults to the parent of this script's directory.

.EXAMPLE
    ./scripts/Test-DocumentationLinks.ps1
#>

[CmdletBinding()]
param(
    [string] $RepositoryRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-GitHubAnchor {
    <#
        GitHub builds an anchor from heading text by lower-casing it, dropping anything that is not
        a letter, digit, space or hyphen, and replacing spaces with hyphens. Punctuation disappears
        rather than becoming a separator, so "1. There is no canvas app, and one cannot be built in
        CI" becomes "1-there-is-no-canvas-app-and-one-cannot-be-built-in-ci".
    #>
    param([Parameter(Mandatory)][string] $HeadingText)

    $text = $HeadingText.Trim()

    # Inline markdown would otherwise contribute its own punctuation to the anchor.
    $text = [regex]::Replace($text, '\[([^\]]*)\]\([^)]*\)', '$1')   # [label](target) -> label
    $text = $text -replace '[`*_]', ''                               # code, bold, italic markers

    $text = $text.ToLowerInvariant()
    $text = [regex]::Replace($text, "[^\p{L}\p{Nd} -]", '')
    $text = $text.Trim() -replace ' ', '-'

    return $text
}

function Get-HeadingAnchor {
    param([Parameter(Mandatory)][string] $Path)

    $anchors = [System.Collections.Generic.HashSet[string]]::new()
    $inFence = $false

    foreach ($line in (Get-Content -Path $Path)) {
        # A "#" inside a fenced code block is a comment or a shell prompt, not a heading.
        if ($line -match '^\s*```') { $inFence = -not $inFence; continue }
        if ($inFence) { continue }

        if ($line -match '^(#{1,6})\s+(.*?)\s*$') {
            [void]$anchors.Add((ConvertTo-GitHubAnchor -HeadingText $Matches[2]))
        }

        # Explicit anchors, should any be added later.
        foreach ($match in [regex]::Matches($line, '<a\s+(?:id|name)="([^"]+)"')) {
            [void]$anchors.Add($match.Groups[1].Value.ToLowerInvariant())
        }
    }

    return $anchors
}

$markdownFiles = @(Get-ChildItem -Path $RepositoryRoot -Filter '*.md' -Recurse -File |
    Where-Object { $_.FullName -notmatch '[\\/](bin|obj|node_modules|\.git)[\\/]' } |
    Sort-Object FullName)

# @() matters: a pipeline that yields nothing produces $null, and under StrictMode $null.Count
# throws, so the intended message below would be replaced by a property error.
if ($markdownFiles.Count -eq 0) {
    throw "No markdown files found under $RepositoryRoot. Refusing to pass a check that examined nothing."
}

# Anchors are needed for any file that is linked to, so gather them once up front.
$anchorCache = @{}
foreach ($file in $markdownFiles) {
    $anchorCache[$file.FullName] = Get-HeadingAnchor -Path $file.FullName
}

Write-Host ''
Write-Host 'Documentation links' -ForegroundColor Cyan
Write-Host ('-' * 70)

$problems = [System.Collections.Generic.List[string]]::new()
$checked = 0

foreach ($file in $markdownFiles) {
    $relativeFile = $file.FullName.Substring($RepositoryRoot.Length).TrimStart('\', '/') -replace '\\', '/'
    $content = Get-Content -Path $file.FullName -Raw

    foreach ($match in [regex]::Matches($content, '\[(?<label>[^\]]*)\]\((?<target>[^)\s]+)(?:\s+"[^"]*")?\)')) {
        $target = $match.Groups['target'].Value

        if ($target -match '^(https?:|mailto:|tel:)') { continue }

        $checked++

        $path = $target
        $anchor = ''
        if ($target.Contains('#')) {
            $parts = $target -split '#', 2
            $path = $parts[0]
            $anchor = $parts[1].ToLowerInvariant()
        }

        # A bare "#anchor" points inside the current file.
        $targetFile = if ([string]::IsNullOrEmpty($path)) {
            $file.FullName
        }
        else {
            $candidate = Join-Path (Split-Path -Parent $file.FullName) ($path -replace '/', [IO.Path]::DirectorySeparatorChar)
            try { [IO.Path]::GetFullPath($candidate) } catch { $candidate }
        }

        if (-not (Test-Path -LiteralPath $targetFile)) {
            # Links that walk up out of docs/ into the repository root, written for GitHub's blob
            # view, are resolved against the repository root instead.
            $fromRoot = Join-Path $RepositoryRoot ($path -replace '^(\.\./)+', '' -replace '/', [IO.Path]::DirectorySeparatorChar)
            if (Test-Path -LiteralPath $fromRoot) {
                $targetFile = $fromRoot
            }
            else {
                $problems.Add("$relativeFile -> $target : file not found")
                continue
            }
        }

        if (-not $anchor) { continue }

        if ($targetFile -notmatch '\.md$') {
            $problems.Add("$relativeFile -> $target : anchor on a non-markdown target")
            continue
        }

        $fullTarget = (Resolve-Path -LiteralPath $targetFile).Path
        if (-not $anchorCache.ContainsKey($fullTarget)) {
            $anchorCache[$fullTarget] = Get-HeadingAnchor -Path $fullTarget
        }

        if (-not $anchorCache[$fullTarget].Contains($anchor)) {
            $targetName = $fullTarget.Substring($RepositoryRoot.Length).TrimStart('\', '/') -replace '\\', '/'
            $problems.Add("$relativeFile -> $target : no heading in $targetName produces anchor '#$anchor'")
        }
    }
}

Write-Host "Checked $checked internal link(s) across $($markdownFiles.Count) file(s)."

if ($problems.Count -eq 0) {
    Write-Host ''
    Write-Host 'Every internal documentation link resolves.' -ForegroundColor Green
    exit 0
}

Write-Host ''
foreach ($problem in $problems) {
    Write-Host "[FAIL] $problem" -ForegroundColor Red
}

Write-Host ''
Write-Host "$($problems.Count) broken link(s)." -ForegroundColor Red
exit 1
