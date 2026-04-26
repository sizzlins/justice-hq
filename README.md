# Sizzlin's Justice HQ

A DFHack mod for Dwarf Fortress that overhauls the justice and counter-intelligence system.

## Features

- **Villain Detection Alerts** — Get notified when villains enter your fortress
- **Looping Interrogations** — Automatically interrogate suspects until they confess
- **Pardon & Execute** — Manage convicts through your Captain of the Guard/Sheriff
- **Villain Network Mapping** — Visualize spy networks, plots, and actor relationships across your fortress
- **Intelligence Tooltips** — Plain-English descriptions for all 16 plot types, 21 roles, and 9 strategies
- **Investigation Progress Markers** — See at a glance which network actors have been interrogated
- **Export & Copy** — Export investigation data to file or clipboard

## Installation

### Steam Workshop (Recommended)
Subscribe on [Steam Workshop](https://steamcommunity.com/sharedfiles/filedetails/?id=3714103991)

### Manual Installation
1. Copy `scripts_modinstalled/gui/justice-hq.lua` to your DFHack `hack/scripts/gui/` directory
2. Copy `info.txt` to your DF mods folder
3. Launch the game and enable the mod

## Usage

The mod adds a **CI-HQ** overlay button to the main fortress view. Click it or run `gui/justice-hq` in the DFHack console.

### Tabs
| Tab | Purpose |
|-----|---------|
| **Suspects** | Lists all detected villains with threat scores |
| **Cases** | Shows active criminal cases from DF's justice system |
| **Convicts** | Manage convicted criminals — pardon or execute |
| **Network** | Maps villain networks, plots, and actor relationships |
| **Case File** | Detailed dossier on the selected suspect |

### Hotkeys
| Key | Action |
|-----|--------|
| `i` | Interrogate selected suspect |
| `p` | Pardon selected convict |
| `k` | Execute selected convict |
| `c` | Export current tab to file |
| `Ctrl+C` | Copy current tab to clipboard |
| `s` | Sort networks (by size or name) |
| `f` | Filter networks (all/active plots only) |

## Requirements

- Dwarf Fortress (Steam version)
- [DFHack](https://docs.dfhack.org/)

## License

MIT
