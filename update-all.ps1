param(
    [ValidateRange(1,16)]
    [int]$Concurrency = 4,
    [ValidateRange(0,10000)]
    [int]$DelayMs = 0
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\utils.ps1"

if (-not (Get-CurlPath)) {
    Write-Host "ERROR: curl was not found. It ships with Windows 10 (1803) and later; on older systems install it from https://curl.se/windows/" -ForegroundColor Red
    exit 1
}

$archiveRoot = Join-Path $PSScriptRoot "archives"

if (-not (Test-Path $archiveRoot)) {
    Write-Host "No archives folder found." -ForegroundColor Yellow
    exit 0
}

$folders = @(Get-ChildItem $archiveRoot -Directory)
if ($folders.Count -eq 0) {
    Write-Host "No archives found." -ForegroundColor Yellow
    exit 0
}

Write-Host "`n  Updating $($folders.Count) archive(s) ...`n" -ForegroundColor Cyan

$updated = 0
$skipped = 0
$removed = 0
$errors = 0

# Pause so each thread fetch is at least 1.1s apart
function Wait-RateLimit($stopwatch) {
    $sleepTime = [math]::Max(0, 1100 - $stopwatch.ElapsedMilliseconds)
    Start-Sleep -Milliseconds $sleepTime
}

foreach ($folder in $folders) {
    # Start stopwatch for dynamic rate limiting
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    $jsonPath = Join-Path $folder.FullName "thread.json"
    $imgDir = Join-Path $folder.FullName "images"

    Write-Host "--- $($folder.Name) ---" -ForegroundColor White

    # Parse board and threadId from folder name
    $info = Parse-ArchiveFolderName $folder.Name
    if (-not $info) {
        Write-Host "  SKIP - unexpected folder name format" -ForegroundColor DarkGray
        $skipped++
        continue
    }
    $board = $info.Board
    $threadId = $info.ThreadId

    # Load existing posts
    $existingPostIds = @{}
    $savedThread = $null
    $savedJson = $null
    if (Test-Path $jsonPath) {
        try {
            $savedJson = [System.IO.File]::ReadAllText($jsonPath, [System.Text.Encoding]::UTF8)
            $savedThread = $savedJson | ConvertFrom-Json
            foreach ($p in $savedThread.posts) {
                $existingPostIds[[string]$p.no] = $true
            }
        } catch {
            Write-Host "  Could not read cached thread.json" -ForegroundColor Yellow
        }
    }

    # Fetch fresh thread page with retries
    $page = Get-7chanThreadPage $board $threadId "    "

    if ($page.Is404) {
        Write-Host "  REMOVED - thread no longer exists (404)" -ForegroundColor Yellow
        $removed++
        Wait-RateLimit $stopwatch
        continue
    }

    if (-not $page.Success) {
        Write-Host "  ERROR - Failed to fetch thread after 3 attempts" -ForegroundColor Red
        $errors++
        Wait-RateLimit $stopwatch
        continue
    }

    try {
        $thread = ConvertFrom-7chanThread $page.Html $board $threadId
    } catch {
        Write-Host "  ERROR - $($_.Exception.Message)" -ForegroundColor Red
        $errors++
        Wait-RateLimit $stopwatch
        continue
    }

    $newPostCount = @($thread.posts | Where-Object { -not $existingPostIds.ContainsKey([string]$_.no) }).Count
    $newJson = ConvertTo-ThreadJson $thread

    $tasks = @(Get-DownloadTasks $thread $imgDir)
    $pending = @($tasks | Where-Object { -not (Test-Path -LiteralPath $_.Dest) })

    if ($savedJson -and $newJson -eq $savedJson -and $pending.Count -eq 0) {
        Write-Host "  UP TO DATE - $(@($thread.posts).Count) posts, no changes" -ForegroundColor Green
        $skipped++
        Wait-RateLimit $stopwatch
        continue
    }

    Write-Host "  $newPostCount new post(s) found" -ForegroundColor Cyan

    if ($savedThread) {
        $freshNos = @{}
        foreach ($p in $thread.posts) { $freshNos[[string]$p.no] = $true }
        $goneCount = @($savedThread.posts | Where-Object { -not $freshNos.ContainsKey([string]$_.no) }).Count
        if ($goneCount -gt 0) {
            Write-Host "  $goneCount post(s) deleted from 7chan since last update (removed from archive)" -ForegroundColor Yellow
        }
        # The archive mirrors 7chan: drop saved copies of files that moderators have since removed
        $removedFiles = Remove-DeletedFiles $savedThread $thread $imgDir
        if ($removedFiles -gt 0) {
            Write-Host "  Deleted $removedFiles saved file(s) that were removed from 7chan" -ForegroundColor Yellow
        }
    }

    if ($pending.Count -gt 0) {
        $delayMsg = if ($DelayMs -gt 0) { ", ${DelayMs}ms delay" } else { "" }
        Write-Host "  Downloading $($pending.Count) files ($Concurrency concurrent$delayMsg) ..." -ForegroundColor Cyan
        $dlFailed = @(Invoke-ParallelDownloads $pending $Concurrency $DelayMs "    ")
        if ($dlFailed.Count -gt 0) {
            Write-Host "  $($dlFailed.Count) download(s) failed" -ForegroundColor Yellow
        }
    }

    # Save updated thread.json (BOM-less UTF-8)
    [System.IO.File]::WriteAllText($jsonPath, $newJson)

    # Regenerate HTML using update-html logic
    try {
        & (Join-Path $PSScriptRoot "update-html.ps1") -ArchiveName $folder.Name
        Write-Host "  UPDATED - $newPostCount new posts" -ForegroundColor Green
        $updated++
    } catch {
        Write-Host "  HTML generation error: $($_.Exception.Message)" -ForegroundColor Red
        $errors++
    }

    # Dynamic Rate Limiting before next thread
    Wait-RateLimit $stopwatch
}

Write-Host "`n========================================" -ForegroundColor Green
Write-Host " Results" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host " Updated:  $updated" -ForegroundColor Green
if ($skipped -gt 0) {
    Write-Host " Skipped:  $skipped (up to date)" -ForegroundColor DarkGray
}
if ($removed -gt 0) {
    Write-Host " Removed:  $removed (404, preserved locally)" -ForegroundColor Yellow
}
if ($errors -gt 0) {
    Write-Host " Errors:   $errors" -ForegroundColor Red
}
Write-Host "========================================" -ForegroundColor Green
