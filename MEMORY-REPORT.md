# Maccy Lite: implementation and validation report

## Upstream baseline

- Latest stable release reviewed: Maccy 2.7.1, commit `eb03ebac3bbf24044c797c06f4304b74e3187835`.
- Upstream `master` reviewed: commit `c376789c5d377b7c520b6f6e91f3f3a1aa28640b`.
- The working tree started at that `master` commit, so it is the implementation base.
- [PR #1446](https://github.com/p0deje/Maccy/pull/1446) discusses reducing memory with external storage and a bounded fetch. Upstream master already deletes child content records during history cleanup. [Issue #1496](https://github.com/p0deje/Maccy/issues/1496) is open, but its status alone does not mean that cleanup is absent.

## Design changes

- The fork uses bundle ID `com.ryuheiyamazawa.MaccyLite`, a separate SwiftData store, and a separate Application Support directory. There is no import from or deletion in the original Maccy store.
- History is capped at 30 total rows at insertion, query, and in-memory list boundaries. The default setting is 30, and at most 10 rows can be pinned. The oldest unpinned rows are removed first.
- Image and other payload data at least 64 KiB is written to `Payloads/<UUID>/original.<type>`; images also get a PNG preview file no larger than 256 pixels on either axis. Writes publish a finished directory atomically. Startup removes unreferenced completed directories and stale temporary directories.
- The SwiftData child row keeps the original pasteboard type, byte count, digest, and image dimensions. Payload bytes are read only when restoring pasteboard formats or generating a requested preview. Multiple representations remain separate, including TIFF and PNG.
- Decoded thumbnails use an `NSCache` capped at 8 MiB and are cleared on memory pressure or payload cleanup. Detailed previews are loaded on demand; closing the preview drops the decorator and `AsyncView` references. OCR is invoked from its existing explicit toolbar action.
- Detail previews are downsampled to at most 2048 pixels on the long axis, so a 4K original is not fully decoded just to fit the popup preview.
- Large text, RTF, and HTML data use the same external payload lifecycle. Short text stays inline. Normal and plain-text paste paths retain their separate representations.

## Builds and tests

Release build command:

```sh
xcodebuild -quiet -project Maccy.xcodeproj -scheme Maccy \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath /tmp/maccy-lite-release CODE_SIGNING_ALLOWED=NO build
```

The Release build completed successfully. The app is packaged in `dist/MaccyLite.app` and is
ad-hoc signed; it is not Developer ID signed or notarized.

The latest unit test run passed 100 tests with no failures. Two existing clipboard tests that
also failed against unmodified upstream were excluded:
`ClipboardTests.testIgnoreApplication` and
`ClipboardTests.testIgnoreAllApplicationsExcept`. A unit test covers 120 large-payload history
updates and verifies that only 30 payload directories remain with no orphans. The final
preview-state cleanup and preview downsampling changes were Release-built and unit-tested.

The UI test runner exits before XCTest establishes its connection, with an early unexpected
exit / signal-kill error. The same runner failure occurred on the untouched upstream baseline,
so UI regression tests could not be completed in this environment. Instruments Allocations
could not attach to the app process (`Failed to attach to target process`).

## Memory measurements

Measurements were taken on an arm64 Mac mini running macOS 27.0. “Physical footprint” is the
`footprint` tool's `phys_footprint`; RSS is the separate resident-set reading from `ps` and is
shown in MiB. Baseline and fork were built in Release mode with signing disabled. Test launches
used isolated temporary homes, and the fork never opened the official Maccy Application Support
store.

| Workload | Upstream physical footprint | Fork physical footprint | Upstream RSS | Fork RSS |
| --- | ---: | ---: | ---: | ---: |
| Empty launch | 29 MB | 31 MB | 89.4 MiB | 96.9 MiB |
| 30 short-text copies | 48 MB | 46 MB | 100.6 MiB | 103.0 MiB |
| 10 unique 4K TIFF images, preview closed | 692 MB | 70 MB | 756 MiB | 127.2 MiB |

The image source was a generated 3840×2160 TIFF fixture; each was stored as a file in the fork.
The baseline retained all ten image payloads in its database-backed history. The fork's
physical footprint was sampled at 5-second intervals after the preview was closed; the final
packaged build remained at 70 MB throughout a 15-second sample. Opening the 2048-pixel detail
preview also measured 70 MB physical footprint. The process peak was 137 MB during launch and
preview setup. The current RSS after preview close was 127.2 MiB, which is separate from
physical footprint.

| Additional check | Result |
| --- | --- |
| 30 mixed image/text/RTF items | Not measured reliably: the accelerated clipboard harness was captured as only four entries in both apps. |
| Search, popup display, image save, paste latency | Not timed with a consistent benchmark. |
| End-to-end UI regressions (hotkey, paste, file URL, ignore rules) | Unit tests passed, but UI tests could not launch on this host; these interactions remain unverified end to end. |
| One-hour soak | Not run. The 120-update storage lifecycle unit test passed. |
| 100-update orphan check | Covered by a 120-update large-payload unit test; zero orphaned payload folders remained. |

The required acceptance case is a 30-item mixed history under 100 MB of physical footprint
after returning to idle. That mixed UI workload and the one-hour soak remain unverified, so this
report does not claim that overall acceptance target. RSS and physical footprint are reported
separately because the RSS values are materially higher.

## Remaining validation limits

- Confirm a repeatable 30-item mixed clipboard run, normal and plain-text paste, and file-URL
  compatibility against destination applications.
- Run UI tests on a host where the XCTest UI runner launches, and complete an hour-long soak.
- Use Instruments Allocations/Leaks on a host that permits attaching to the running app.
- Benchmark startup, popup, save, and paste latency before and after the change.
- Obtain Developer ID signing and notarization before distributing outside local development.
