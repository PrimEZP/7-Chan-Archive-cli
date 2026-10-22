# 7chan Thread Archiver

> Download entire 7chan threads — every image, video and file, full quality. Generates a single self-contained HTML viewer with authentic 7chan (Burichan) styling that works completely offline.

A port of [4chan-archive-cli](https://github.com/divyanshchandhok/4chan-archive-cli) v1.1.0 to [7chan.org](https://7chan.org/).

**Get started:**

```
archive.bat https://7chan.org/pr/res/3818.html
```

### Why this tool?

7chan has no public API and no third-party archives, so a thread is gone once it's pruned. This tool reads the thread page directly, downloads all attachments in parallel, and generates a single HTML file with 7chan's look, quote hover previews, inline expansion, grid layout and native video playback, all offline.

### Features

- **Full quality files**: original images, videos, Flash, audio and documents (PDFs and other uploads) without compression
- **Multi-file posts**: 7chan posts can carry several attachments; each one is downloaded and shown
- **Offline HTML viewer**: single file opens in any browser, works completely offline under `file://`
- **Parallel downloads**: concurrent downloads with configurable limits (defaults to 4, supports 1-16)
- **Native video and audio players**: WebM/MP4 in an HTML5 player (autoplay, loop, auto-mute), MP3/OGG with inline audio controls
- **Expand / collapse images**: toggle all static images inline at once
- **Drag-to-resize**: expanded images and videos can be resized by dragging, aspect ratio preserved
- **Quote hover previews**: hover a `>>quotelink` to see the referenced post
- **Dynamic backlinks**: auto-generated backlinks with scroll-to-highlight navigation
- **Authentic Burichan styling**: 7chan's default theme, with greentext, tripcodes, capcodes (Admin/Mod), spoilers, and sticky/locked flags
- **List / Grid toggle**: switch between 7chan's single-column layout and a responsive card grid
- **Mirrors moderation**: files 7chan shows as "File Removed" are never downloaded, and when you update an archive, posts and files moderators have deleted since are removed from it, including the saved copies
- **Emoticons saved locally**: 7chan's inline emoticon images are downloaded too
- **Idempotent downloads**: skips files you already have; interrupted downloads are never mistaken for complete ones
- **Error resilience**: retries with backoff, connection timeouts, and rate limiting

---

## Requirements

- Windows 10 (1803) or later, with PowerShell 5.1+ (both included)
- `curl`, which ships with Windows 10/11 as `curl.exe`

> **Why curl?** 7chan sits behind Cloudflare, which rejects PowerShell's built-in web client (`Invoke-WebRequest`) with HTTP 403. All requests go through `curl.exe` instead, so nothing extra needs installing.

On macOS/Linux, the `.sh` wrappers run the same scripts with PowerShell 7 (`pwsh`) and the system `curl`.

## Quick Start

### Single thread

```
archive.bat https://7chan.org/pr/res/3818.html
```

Double-clicking `archive.bat` asks for a URL instead.

### Interactive mode (paste multiple URLs)

```
archive-interactive.bat
```

Or run the PowerShell script directly:

```powershell
.\archive-interactive.ps1
```

### PowerShell directly

```powershell
.\archive.ps1 "https://7chan.org/pr/res/3818.html"
```

If PowerShell refuses to run scripts, use the `.bat` launchers (they pass `-ExecutionPolicy Bypass` for that one run) or run `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` once.

### List archived threads

```
list-archives.bat
```

### Refresh UI on all archives

If you update the tool and want existing archives to use the latest HTML/template:

```
update-html.bat
```

Or refresh a single archive:

```powershell
.\update-html.ps1 -ArchiveName "pr_3818_newbie-thread"
```

`-ArchiveName` is the folder name under `archives/`, as shown by `list-archives.bat`.

This regenerates `thread.html` from the saved `thread.json` without re-downloading anything. It works for threads that are no longer on 7chan.

### Auto-update all live threads

Fetch every archived thread from 7chan, download new posts/files, and regenerate HTML:

```
update-all.bat
```

- Threads that are still alive get new posts downloaded, and posts or files deleted by moderators are removed from the archive
- Threads that have been removed entirely (404, usually pruned for age) are marked as REMOVED, and their local files are preserved
- Threads with no changes are skipped
- Requests are spaced at least 1.1 seconds apart

## Supported URL formats

All of these work:

```
https://7chan.org/pr/res/3818.html
https://www.7chan.org/pr/res/3818.html
https://7chan.org/pr/res/3818.html#3930
https://7chan.org/pr/res/3818+50.html
7chan.org/pr/res/3818
```

## Options

| Parameter | Default | Description |
|-----------|---------|-------------|
| `Url` | *(required)* | Thread URL to archive |
| `-Concurrency` | `4` | Number of parallel downloads (1-16) |
| `-DelayMs` | `0` | Delay between file downloads in milliseconds (0-10000) to prevent rate limiting |

Example with custom parallelism and rate-limiting delay:

```powershell
.\archive.ps1 "https://7chan.org/pr/res/3818.html" -Concurrency 4 -DelayMs 250
```

## Output structure

```
archives/
  pr_3818_newbie-thread/
    thread.html          <- open this in a browser
    thread.json          <- parsed thread, used for updates and regenerating HTML
    images/
      136958949722.jpg   <- full quality image
      136958949722s.jpg  <- thumbnail
      Some_Book.pdf      <- non-image uploads keep their 7chan file name
      generic.png        <- 7chan's file-type icon, used as the thumbnail for documents
      emotes/            <- emoticons used in posts
      ...
```

The `thread.html` file is fully self-contained. It references files in the local `images/` folder, so it works with no internet connection.

## Updating archives

If a thread is already archived, the tool will ask whether to update:

```
Thread already archived at: archives/pr_3818_newbie-thread
Update with new posts? (Y/n)
```

Press Enter (or `y`) to fetch new posts. Only missing files are downloaded; existing files are never re-downloaded. The HTML is regenerated with all posts.

The archive always matches the thread as it currently is on 7chan:

```
  0 new post(s) found
  1 post(s) deleted from 7chan since last update (removed from archive)
  Deleted 2 saved file(s) that were removed from 7chan
```

Only files the archive itself downloaded for those posts are deleted; anything else you put in the folder is left alone.

## Notes

- 7chan has no JSON API, so the tool parses thread pages (Kusaba X markup). If 7chan changes its layout, the parser in `utils.ps1` is the place to update.
- Deleted threads or 404s show an error. Existing archives are never touched when an update fails.
- Thumbnails are downloaded alongside full files for fast browsing.
- Flash (`.swf`) files are saved as-is; their thumbnail links to the file. Browsers can't play Flash, so open them with a standalone player such as [Ruffle](https://ruffle.rs/) (what 7chan uses).
- The viewer's "Source" link points back to the thread on 7chan.
- Please be considerate of 7chan's servers: the defaults (4 parallel downloads, 1.1 s between threads in `update-all`) are deliberately modest.

## Development

```
utils.ps1             Fetching (curl), 7chan page parser, download pool, file bookkeeping
archive.ps1           Archive or update one thread
update-all.ps1        Update every archive
update-html.ps1       Render thread.json into thread.html (template, CSS and viewer JavaScript)
archive-interactive.ps1, list-archives.ps1
*.bat / *.sh          Launchers for Windows and macOS/Linux
tests/run-tests.ps1   Offline test suite
tests/fixtures/       Synthetic 7chan thread page covering every markup case the parser handles
```

Run the tests (no network access needed):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
```

They also run on GitHub Actions under Windows PowerShell 5.1 and PowerShell 7 on Windows, Linux and macOS.

Keep `.ps1` files ASCII-only: Windows PowerShell 5.1 reads BOM-less files as ANSI, so any other character gets garbled. The test suite checks this.

## Disclaimer

This project is not affiliated with 7chan. You are responsible for what you download and for following 7chan's rules and your local laws.

## Credits

Based on [4chan-archive-cli](https://github.com/divyanshchandhok/4chan-archive-cli) by Divyansh Chandhok (MIT).
