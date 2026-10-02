# OpenWhoop

An open-source iOS companion app for the WHOOP 4.0 strap. Connects over Bluetooth to read heart rate, HRV, sleep, workouts, and strain locally on-device — no WHOOP account or cloud subscription required.


## Architecture

```mermaid
flowchart TD
    Strap[(WHOOP 4.0 strap)] <-->|BLE| BLE

    subgraph BLE["BLE/"]
        Mgr[BLEManager] --> FR[FrameRouter]
        Cmd[Commands]
        HR[StandardHeartRate]
        Stuck[StuckStrapDetector]
    end

    subgraph Collect["Collect/"]
        Coll[Collector] --> Store[(Local stores<br/>StorePaths, JSON caches)]
        Back[Backfiller · BackfillPolicy]
        Clock[ClockCorrelation / ClockPolicy]
        Prune[PrunePolicy]
    end

    subgraph Analysis["Analysis/"]
        Eng[LocalMetricsEngine]
        Eng --> HRV & RHR[RestingHR] & Sleep[SleepDetection] & Rec[Recovery] & Str[Strain] & SpO2 & Skin[SkinTemp] & Steps[StepCounter] & Ex[ExerciseDetection]
    end

    subgraph UI["Tabs/ · Charts/ · Live/ · Design/"]
        Today & SleepTab[Sleep] & Trends
    end

    Alerts["Alerts/ · Alarm/<br/>battery, recovery, smart alarm"]
    Up["Upload/ · Sync/<br/>optional ServerSync"]

    FR --> Coll
    Back --> Mgr
    Store --> Eng --> Store
    Store --> UI
    FR --> Live[Live/LiveState] --> UI
    Eng --> Alerts
    Store -.optional.-> Up -->|WHOOP_BASE_URL| Server[(Self-hosted server)]
```

More detail: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)

## Screenshots

*Mockups with simulated data — illustrative only, not live app captures.*

| Today | Sleep | Trends |
|:---:|:---:|:---:|
| ![Today tab with recovery ring](docs/screenshots/today.svg) | ![Sleep tab with hypnogram](docs/screenshots/sleep.svg) | ![Trends tab with charts](docs/screenshots/trends.svg) |

## Requirements

- Xcode 16+, iOS 16+
- A WHOOP 4.0 strap
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate the Xcode project from `project.yml`

## Getting started

```bash
xcodegen generate
open OpenWhoop.xcodeproj
```

Fill in `OpenWhoop/Config/Secrets.xcconfig` with your `WHOOP_BASE_URL`, `WHOOP_API_KEY`, and `WHOOP_DEVICE_ID` before building.

## Project structure

- `OpenWhoop/BLE` — Bluetooth connection and protocol handling for the WHOOP strap
- `OpenWhoop/Metrics` — recovery, strain, sleep, and HRV data pipeline
- `OpenWhoop/Analysis` — on-device metrics computation
- `OpenWhoop/Tabs` — the five main app screens (Today, Sleep, Trends, Workouts, Device)
- `OpenWhoop/Design` — shared design tokens (colors, spacing, typography)
- `OpenWhoopTests` — unit tests
- `maestro/` — end-to-end UI test flows
