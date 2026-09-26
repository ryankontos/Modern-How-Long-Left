# How Long Left

How Long Left is a fast, event-focused Apple platform app. The shared backend lives in the `HLLKit` Swift package and is used by the iOS app, the independent watch app, widgets, complications, and Live Activities.

## Project layout

```text
HowLongLeft.xcworkspace/
├── HowLongLeft/                         # JSON Xcode project
│   ├── HowLongLeft/                     # UIKit lifecycle + SwiftUI shell
│   ├── HowLongLeftWatch Watch App/      # independent watchOS app
│   ├── HowLongLeftWidgets/              # iOS widget extension
│   └── HowLongLeftComplications/        # watch complication extension
└── ../Packages/HLLKit/                  # shared package
    └── Sources/HLLKit/
        ├── Domain/                      # HLLEvent and durable records
        ├── EventKit/                    # actor-isolated EventKit adapter
        ├── Events/                      # indexed query and reduction pipeline
        ├── Persistence/                 # Core Data + CloudKit repository
        ├── Runtime/                     # one runtime per process
        ├── Widgets/                     # extension snapshot and WidgetKit types
        └── Activities/                  # iOS Live Activity policy/coordinator
```

## Data flow

`EventKit` and user-event records are normalized to `HLLEvent`. The event engine indexes that immutable value and applies a bounded query, calendar-context visibility, hidden annotations, and optional pin annotations. Every consumer uses that same reducer, so an event hidden in the app is also hidden in widgets, complications, and Live Activities.

`EKEvent` never crosses the HLLKit boundary. Stable identities are resolved from EventKit identifiers, occurrence dates, and a conservative fingerprint fallback. A portable key is retained when a calendar profile and EventKit external identifier make cross-device matching safe.

## Storage

`NSPersistentCloudKitContainer` owns two stores:

- `Cloud.sqlite` stores user events, app settings, calendar profiles and per-context visibility rules.
- `Local.sqlite` stores EventKit identity aliases and device-local Live Activity policies.

The model uses scalar indexed keys and an encoded payload so CloudKit records remain small and schema changes stay isolated from the query engine. The app is the only process that opens the CloudKit mirror. Extensions read an atomic App Group projection and refresh EventKit directly, avoiding multiple CloudKit mirrors racing in extension processes.

Maintenance is bounded and infrequent: expired occurrence annotations, old local identity aliases, duplicate logical rows, and safely exported persistent history are removed during a background maintenance pass no more than monthly. The App Group file is a single replacement snapshot, so it does not accumulate one file per refresh.

The app also writes the latest extension projection to one replaceable private CloudKit record. Extensions try that record with a short timeout and select the newest result between CloudKit and the local App Group snapshot. If the account is offline or unavailable, the local snapshot remains usable.

## Extensions and Live Activities

Widgets and complications use `AppIntentConfiguration`. Users can choose current, in-progress, or upcoming events, include or exclude all-day events, select one event, choose a style, and choose a row count. WatchOS intentionally returns no recommendations so configuration remains explicit.

The extension loader refreshes EventKit on every timeline request when access is available, expands user recurrences from the cached definitions, and applies the cached settings and annotations before producing a timeline. Timer text is date-driven; progress and detailed styles receive bounded 15-minute intermediate entries.

Live Activities use the same `HLLEvent` query path. A user can start one immediately or create a local policy for a specific event, calendar profile, or all events. Policies can schedule a start before an event, reconcile settings and hidden events, update changed dates, and end activities that are no longer visible.

## Requirements

- Xcode 27.2 beta (the project uses the new JSON `.xcproj` format).
- Latest major iOS, watchOS, and macOS SDKs available in the selected Xcode.
- A real Apple Team, bundle identifier, App Group, and CloudKit container before device signing.

The checked-in identifiers are development placeholders (`com.ryan.HowLongLeft`, `group.com.ryan.HowLongLeft`, and `iCloud.com.ryan.HowLongLeft`). Replace them in the project and entitlements for a real account.

## Verification

```sh
cd Packages/HLLKit
swift test

cd ../..
xcodebuild -workspace HowLongLeft.xcworkspace \
  -scheme HowLongLeft \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/HLLDerivedIOS \
  CODE_SIGNING_ALLOWED=NO build

xcodebuild -workspace HowLongLeft.xcworkspace \
  -scheme 'HowLongLeftWatch Watch App' \
  -destination 'generic/platform=watchOS' \
  -derivedDataPath /tmp/HLLDerivedWatch \
  CODE_SIGNING_ALLOWED=NO build
```

The package tests cover stable identity, indexed filters, calendar contexts, recurrence expansion, local persistence, and hidden-event extension filtering.
