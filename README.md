# ClaudeTracker

A lightweight native macOS menu bar app that tracks your [Claude Code](https://claude.ai/code) token usage and costs in real time — no account login required.

![ClaudeTracker menu bar screenshot](https://github.com/cybereager/claude-tracker/assets/placeholder/menubar.png)

---

## Features

- **Real-time cost tracking** — reads Claude Code's local JSONL conversation files directly from `~/.claude/projects/`
- **Subscription usage mode** — shows 5-hour session % and weekly % bars (like Claude's own usage page)
- **Auto-detect your plan** — reads `~/.claude.json` to auto-fill your email and subscription tier (Pro / Max 5x / Max 20x)
- **Per-model breakdown** — cost and token usage split by Sonnet, Opus, Haiku
- **Per-project breakdown** — see which projects consume the most tokens
- **Incremental parsing** — only reads new bytes appended since last refresh; handles 40+ MB conversation files efficiently
- **Zero network access** — 100% local, no telemetry, no credentials sent anywhere
- **Tiny footprint** — ~260 KB DMG, no frameworks, no external dependencies

### Menu bar modes

| Mode | Example |
|------|---------|
| API Cost | `◆ $1.24` |
| Subscription (with plan limits) | `◆ 23% \| 50%` |
| Subscription (API plan) | `◆ 42 msgs` |

---

## Requirements

- macOS 13 Ventura or later
- [Claude Code](https://claude.ai/code) installed and used at least once (so `~/.claude/projects/` exists)

---

## Installation

### Option A — DMG (recommended)

1. Download `ClaudeTracker-1.0.0.dmg` from the [latest release](https://github.com/cybereager/claude-tracker/releases/latest)
2. Open the DMG and drag **ClaudeTracker** to your **Applications** folder
3. Launch from Applications — it appears in your menu bar immediately

> **First launch:** macOS may show "unidentified developer" because the app is not notarized.
> Right-click the app → **Open** → **Open** to bypass Gatekeeper once.

### Option B — Build from source

```bash
git clone https://github.com/cybereager/claude-tracker.git
cd claude-tracker
make release     # builds .app + DMG in dist/
open dist/ClaudeTracker.app
```

Requirements: Xcode Command Line Tools (`xcode-select --install`)

---

## Usage

**Left-click** the menu bar icon to open the usage popover.
**Right-click** for quick actions: _Reload All Data_ / _Quit_.

### Subscription mode

1. Open the popover and switch to **Subscription** tab
2. Your email and plan are auto-detected from `~/.claude.json`
3. Select your plan manually if auto-detection doesn't match:
   - **Pro** — ~186 API calls / 5 hr, ~1 950 / week
   - **Max (5x)** — ~930 / 5 hr, ~9 750 / week
   - **Max (20x)** — ~3 720 / 5 hr, ~39 000 / week

> Limits are estimated by counting all complete API responses (non-null `stop_reason`) — the same unit Claude's own usage dashboard uses.

---

## How it works

Claude Code stores every conversation turn as a JSONL file under `~/.claude/projects/<encoded-path>/<session-id>.jsonl`. Each assistant message includes a `message.usage` object with token counts:

```json
{
  "type": "assistant",
  "timestamp": "2026-02-28T10:00:00.000Z",
  "message": {
    "model": "claude-sonnet-4-6-20251101",
    "stop_reason": "end_turn",
    "usage": {
      "input_tokens": 4821,
      "output_tokens": 312,
      "cache_creation_input_tokens": 0,
      "cache_read_input_tokens": 18432
    }
  }
}
```

ClaudeTracker reads these files with a 64 KB streaming parser, tracks the last parsed byte offset per file, and recomputes totals every 60 seconds without re-reading data it has already processed.

### Cost calculation

| Model | Input | Output | Cache Write | Cache Read |
|-------|-------|--------|-------------|------------|
| Claude Opus 4 | $15 / MTok | $75 / MTok | $18.75 / MTok | $1.50 / MTok |
| Claude Sonnet 4 | $3 / MTok | $15 / MTok | $3.75 / MTok | $0.30 / MTok |
| Claude Haiku 4.5 | $0.80 / MTok | $4 / MTok | $1.00 / MTok | $0.08 / MTok |

---

## Building & releasing

```bash
make              # debug build
make release      # release build + .app bundle + DMG → dist/
make clean        # remove build artifacts
```

The `make release` command:
1. Compiles with `swift build -c release`
2. Assembles `dist/ClaudeTracker.app` with the correct Info.plist and icon
3. Ad-hoc signs the bundle
4. Creates `dist/ClaudeTracker-<version>.dmg` with a drag-to-install layout

---

## Project structure

```
claude-tracker/
├── Package.swift
├── Makefile
├── Resources/
│   ├── AppIcon.icns          # App icon (512×512 source in iconset)
│   ├── AppIcon.iconset/      # All required macOS icon sizes
│   └── Info.plist            # LSUIElement=true (no dock icon)
└── Sources/
    └── ClaudeTracker/
        ├── main.swift            # NSApplication entry point
        ├── AppDelegate.swift     # NSApplicationDelegate
        ├── Models.swift          # Data types, ModelKind, Pricing, PlanType
        ├── UsageParser.swift     # Streaming JSONL parser + byte-offset cache
        ├── CostCalculator.swift  # Token → USD aggregation + formatters
        ├── AccountDetector.swift # Auto-detects plan from ~/.claude.json
        ├── MenuBarManager.swift  # NSStatusItem + NSPopover + 60s refresh
        └── PopoverView.swift     # SwiftUI popover UI
```

---

## Contributing

Pull requests are welcome. For major changes, please open an issue first.

- All logic in `CostCalculator.swift` is a pure function — easy to test
- Pricing tables are in `Models.swift` → `ModelKind.pricing`
- Subscription limits are in `Models.swift` → `PlanType.fiveHourLimit` / `weeklyLimit`

---

## License

MIT — see [LICENSE](LICENSE)
