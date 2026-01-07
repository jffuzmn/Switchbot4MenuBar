# Quick Start Guide

## 1. Download & Install

```bash
# Download from Releases page, unzip, then:
xattr -cr SwitchBotCO2.app
mv SwitchBotCO2.app /Applications/
open /Applications/SwitchBotCO2.app
```

## 2. Grant Bluetooth Permission

When prompted, click **Allow** to grant Bluetooth access.

## 3. That's It!

The app will automatically find your SwitchBot Meter Pro CO₂ and display readings in your menu bar.

---

## Build from Source

```bash
./build.sh
open build/SwitchBotCO2.app
```

## Troubleshooting

**Gatekeeper blocks the app:**
```bash
xattr -cr /Applications/SwitchBotCO2.app
```

**Not finding device:**
- Ensure SwitchBot Meter Pro CO₂ is on and within range
- Check System Settings → Privacy & Security → Bluetooth
