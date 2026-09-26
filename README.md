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
        ├── Activities/                  # iOS Live Activity policy/coordinator
        ├── Commerce/                    # StoreKit 2 entitlements and cross-device cache
        └── Notifications/               # entitlement-gated notification scheduler
```

## Data flow

`EventKit` and user-event records are normalized to `HLLEvent`. The event engine indexes that immutable value and applies a bounded query, calendar-context visibility, hidden annotations, and optional pin annotations. Every consumer uses that same reducer, so an event hidden in the app is also hidden in widgets, complications, and Live Activities.

`EKEvent` never crosses the HLLKit boundary. Stable identities are resolved from EventKit identifiers, occurrence dates, and a conservative fingerprint fallback. A portable key is retained when a calendar profile and EventKit external identifier make cross-device matching safe.

## Reading the code

Start with the value types in `Packages/HLLKit/Sources/HLLKit/Domain/`. `HLLEvent` is the event the rest of the app understands; `HLLEventQuery` describes what a caller wants; `HLLCalendarPreference` and `HLLEventAnnotation` hold visibility, hidden, and pinned choices. These types contain the shared vocabulary, not UI or database code.

To follow a calendar event into the app, read these files in order:

1. `EventKit/HLLEventKitSource.swift` is the only adapter that talks to EventKit. It turns EventKit results into plain sendable values.
2. `Events/HLLEventEngine.swift` joins calendar values with personal event definitions, resolves identity, and runs the query. `Events/HLLEventIndex.swift` and `Events/HLLEventReducer.swift` handle fast filtering and visibility rules.
3. `Runtime/HLLRuntime.swift` creates the shared services and publishes the small extension snapshot.
4. `HowLongLeft/HLLAppModel.swift` loads the local launch snapshot first, then refreshes from HLLKit. `ContentView.swift` displays the current and upcoming lists; `EventViews.swift` contains cards and details.

The refresh path follows one direction: a source notification reaches the app model, which debounces it and invalidates the engine. The engine clears its revision cache and publishes one change. The model then queries again, publishes the App Group snapshot, and asks WidgetKit to reload only when visible content changed. Start/end timers reclassify already-loaded events in memory on detached work; they do not query storage or block list scrolling.

For widgets and complications, start at `Widgets/HLLWidget.swift` for configuration, then `Widgets/HLLExtensionSnapshotLoader.swift` for a fresh platform-local EventKit read and portable settings, and `Widgets/HLLWidgetTimelinePlanner.swift` for the dated entries. `HLLWidgetEventView.swift` renders an entry. The planner owns event transitions; the provider's periodic refresh is a chance to discover edits made while apps are asleep.

For storage, `Persistence/HLLRepository.swift` is the typed doorway and `Persistence/HLLDatabase.swift` owns the two Core Data stores. Callers should use repository methods rather than constructing database records. Calendar occurrences stay device-local; only portable settings and user-created event definitions sync through CloudKit.

For purchases, follow `Commerce/HLLPurchaseCoordinator.swift` to see StoreKit verification, then `Commerce/HLLPurchaseSnapshotStore.swift` for the local cache, CloudKit mirror, and retry outbox. Widgets read entitlements through `Commerce/HLLPurchaseEntitlementReader.swift`; they never start the app's long-running transaction listener.

The app target's SwiftUI settings are grouped by topic: `CalendarSettingsViews.swift`, `FeatureSettingsViews.swift`, `PurchaseSettingsViews.swift`, and `OtherSettingsViews.swift`. The watch target has its own model and views because watchOS uses its own EventKit calendars and must keep working without the iPhone.

## Storage

`NSPersistentCloudKitContainer` owns two stores:

- `Cloud.sqlite` stores user events, app settings, calendar profiles and per-context visibility rules.
- `Local.sqlite` stores EventKit identity aliases and device-local Live Activity policies.

The model uses scalar indexed keys and an encoded payload so CloudKit records remain small and schema changes stay isolated from the query engine. The app is the only process that opens the CloudKit mirror. Extensions read an atomic App Group projection and refresh EventKit directly, avoiding multiple CloudKit mirrors racing in extension processes.

Maintenance is bounded and infrequent: expired occurrence annotations, old local identity aliases, duplicate logical rows, and safely exported persistent history are removed during a background maintenance pass no more than monthly. The App Group file is a single replacement snapshot, so it does not accumulate one file per refresh.

Calendar occurrences are never written to CloudKit. The App Group snapshot may contain local EventKit occurrences for fast same-device launch, but it is not synced. Extensions read their platform's EventKit store directly whenever access is available. CloudKit carries only portable settings and user-created data, so a watch cannot import an iPhone calendar event.

`HLLCloudKitSubscriptionInstaller` creates idempotent silent-push query subscriptions for the shared settings and purchase projections. CloudKit may coalesce pushes, so the app and watch treat each notification as a refresh hint and rebuild from authoritative sources. Subscription setup runs in a utility task after the stores open and never delays the first frame.

A second small CloudKit record contains only portable shared settings: synced user-event definitions, calendar profiles and visibility, and portable hidden/pinned annotations. iOS and watchOS merge this overlay with their own EventKit projection, so a complication can learn about a cross-device setting change without importing the other platform's calendar IDs. A mirrored mutation stamp, advanced for creates, edits, and deletions, prevents a device with stale local data from replacing a newer whole-document projection. A single-file App Group outbox retries a failed CloudKit projection write without adding writes to the steady-state refresh path.

`NSPersistentCloudKitContainer` is used for durable app data, not opened by extensions. This keeps Core Data's import/export machinery in one process and avoids the multi-process mirroring races that can make an extension hang or duplicate records. HLLKit enables persistent history and remote-change notifications, uses separate Cloud and Local configurations, upserts by logical key, and prunes only old exported history. Deleting a personal event also removes its hide/pin annotations and event-specific automatic tracking rules. The App Group snapshot is the only occurrence cache; the CloudKit projection contains portable settings and user data only.

## Paid capabilities

StoreKit 2 is the authority for widgets, complications, Live Activities, and notifications. `HLLPurchaseCoordinator` listens to `Transaction.updates`, evaluates verified latest/current entitlements, and treats expiry and revocation as locked immediately. Product metadata is configuration, so the same code supports a non-consumable, an auto-renewing subscription, or a non-renewing subscription without changing the event engine.

The current shipping map retains the existing product identifiers (`HLLWidget` and `ComplicationIAPHLL`) while the App Store catalog is finalized. The coordinator persists a small, replace-in-place entitlement projection in the App Group and the user's private CloudKit database. WatchConnectivity sends the same projection to the paired watch. A one-file outbox retries a failed CloudKit entitlement upload, and verification timestamps prevent a delayed device from replacing a newer result. These copies are caches and backups only: app, watch, and extensions read StoreKit when available, use the cache when offline, and always re-check entitlement dates before rendering or scheduling. Explicit restore calls `AppStore.sync()`; the transaction listener handles normal cross-device delivery.

Widget and complication timelines return a lock entry when the capability is unavailable, so they never expose stale event data after a revocation. The configuration intent remains explicit on watchOS 27 and offers current, in-progress, all/upcoming, soonest-countdown selection, countdown-date or start-date ordering, all-day filtering, a selected event, and multiple countdown/progress styles. Live Activity and notification scheduling are guarded in HLLKit at their service boundaries as well as in the app UI.

The iOS shell uses a UIKit app and scene delegate with a `UIHostingController` root. SwiftUI provides a Current tab with live countdowns, a separate Upcoming tab, event details, context-menu actions, and a settings sheet. The watch app has its own runtime and a compact vertical-page interface, so it continues to use watchOS calendars when the iPhone is unavailable. Watch event actions live on the detail screen because context menus aren’t supported on watchOS. Both app targets enable remote background notifications; their delegates refresh local EventKit projections and reload WidgetKit after a CloudKit change. Both apps keep the first frame blank until the first event snapshot exists, then fade the loaded content in.

## Extensions and Live Activities

Widgets and complications use `AppIntentConfiguration` and a shared `WidgetConfigurationIntent`. Users can choose current, in-progress, or upcoming events, include or exclude all-day events, select one event, choose a style, and choose a row count. The intent's parameter summary keeps the configuration order clear on both iPhone and watch. On watchOS 27, people edit these intent values directly for each complication, so the provider returns no preset recommendations.

The extension loader refreshes EventKit on every timeline request when access is available, expands user recurrences from the cached definitions, and applies the cached settings and annotations before producing a timeline. If calendar access is denied or revoked, it drops cached calendar events and keeps only personal events. Local EventKit and CloudKit settings reads begin concurrently. A 15-minute App Group cache prevents several complication configurations from repeating the same network request. Timer text is date-driven; progress and detailed styles receive bounded 15-minute intermediate entries only for events that can actually appear.

Timelines use a calendar-aligned window from midnight through midnight two days later. Start and end transitions remain stable throughout the day, and smart countdown ordering uses an event's end while it is running and its start while it is upcoming. Current-or-next mode prefers an active event; soonest-countdown mode compares the next relevant boundary across active and upcoming events. A specifically selected event overrides the general mode. iOS requests background refresh opportunities and watchOS requests its complication-backed refresh budget; both publish atomically and call `WidgetCenter` only when renderable content changed.

The watch extension never falls back to an iPhone calendar projection when watch EventKit access is unavailable. It shows only portable user events until watch calendars can be read, then replaces that seed with the watch's own EventKit snapshot.

Live Activities use the same `HLLEvent` query path. A user can start one immediately or create a local policy for a specific event, calendar profile, or all events. Policies can schedule a start before an event, reconcile settings and hidden events, update changed dates, and end activities that are no longer visible.

## Requirements

- Xcode 27.2 beta (the project uses the new JSON `.xcproj` format).
- Latest major iOS, watchOS, and macOS SDKs available in the selected Xcode.
- A real Apple Team and provisioning profiles before device signing.

The checked-in identifiers and version metadata are carried over from the original How Long Left project: team `5AMFX8X5ZN`, iOS bundle `com.ryankontos.How-Long-Left`, watch bundle `com.ryankontos.How-Long-Left.watchkit`, App Group `group.com.ryankontos.How-Long-Left`, CloudKit container `iCloud.ryankontos.howlongleft`, version `3.0`, iOS build `253`, and watch build `247`. The original project never shipped, so this workspace does not include a migration layer.

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

The package tests cover stable identity, indexed filters, calendar contexts, recurrence expansion, local persistence, hidden-event extension filtering, status boundaries, entitlement expiry/revocation, projection fingerprints, and smart timeline selection.
