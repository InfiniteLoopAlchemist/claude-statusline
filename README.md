# claude-statusline

Custom Claude Code statusline showing API usage (5-hour session + weekly) with reset times.

![screenshot](screenshot.png)

## What it shows

- **Line 1**: Model, context window usage, thinking mode
- **Line 2**: 5-hour session usage + 7-day weekly usage (colored dot bars) + extra usage if enabled
- **Line 3**: Reset times + session cost + git branch

Usage data comes from the undocumented OAuth usage API (`/api/oauth/usage`). Cached for 60s so it doesn't spam the endpoint.

## Install

```bash
# Copy the script
cp statusline.sh ~/.claude/statusline.sh
chmod +x ~/.claude/statusline.sh
```

Add to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline.sh"
  }
}
```

## Requirements

- macOS (uses Keychain for OAuth token)
- `jq` and `curl`
- `python3` (for ISO date parsing)
- Claude Code with OAuth login (the token is stored automatically)

## How it works

- Reads the JSON payload Claude Code pipes to statusline scripts via stdin
- Extracts OAuth token from macOS Keychain (`Claude Code-credentials`)
- Calls `https://api.anthropic.com/api/oauth/usage` to get 5-hour and 7-day rate limit data
- Caches the API response for 60 seconds at `/tmp/.claude-usage-cache.json`
- API fetch runs in the background so it never blocks the statusline render