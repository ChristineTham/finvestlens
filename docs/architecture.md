# FinvestLens — Technical Architecture

| | |
|---|---|
| **Document status** | As-built v1.0 (P0–P6 shipped) |
| **Last updated** | 2026-07-13 |
| **Companions** | [PRD](prd.md) · [Porting Strategy](porting.md) |
| **Scope** | Target architecture, technology choices, native file format, and how the hard problems are solved |

This document evaluates implementation alternatives, recommends specific technologies and Swift packages, and defines the module layout and the **native document format**. Decisions are recorded ADR-style: **context → options → decision → rationale**.

> **v0.2 direction change.** FinvestLens is **native-first above all else**. Two consequences drive this revision: (1) money uses **Swift-native `Decimal`**, and we **do not** aim for bug-for-bug numeric parity with GnuCash — rounding discrepancies are acceptable and tests tolerate them; (2) the app is a **document-based app with its own native file format** (a single SQLite file) that can live on a NAS, with **application-level locking**. **SwiftData is dropped**; the in-memory engine model is the source of truth, persisted through GRDB/SQLite. GnuCash XML is demoted to an **import/export interchange format**, not the app's save format.

---

## 1. Principles (priority order)

- **P1 — Native first, always.** Prefer first-party Apple frameworks and idiomatic Swift over anything that imports foreign runtimes or models. This principle **outranks** fidelity and engine-purity concerns when they conflict.
- **P2 — Own document format.** The app opens and saves its **own** native file. Interoperability with GnuCash is achieved by import/export, not by adopting GnuCash's on-disk format as our store.
- **P3 — Good-enough fidelity.** Match GnuCash's *data and semantics* well enough to be useful and round-trip the important objects; do **not** chase bit-exact arithmetic. Tests accept small rounding differences.
- **P4 — Swap-able boundaries.** Persistence, file IO, XML interchange, and quotes sit behind protocols so implementations can change without touching the engine or UI.
- **P5 — Engine independence.** The accounting engine has no UI or persistence dependencies (it may use Foundation value types like `Decimal`/`Date`). It is deterministic and unit-tested.
- **P6 — Data safety on shared storage.** A document may live on a network share accessed by multiple machines; the app must never let two writers corrupt it.

---

## 2. Layered architecture and module (SPM target) layout

```
FinvestLensApp (macOS / iPadOS / iOS)          ← SwiftUI, per-platform
   │
   ├── FeatureUI          SwiftUI views + AppModel (@Observable view model)
   ├── Reports            report computation (Swift) + Swift Charts rendering
   ├── Interchange        GnuCash XML import/export · QIF/OFX/CSV · import matcher
   ├── Rules              rules engine · merchant heuristics · operator search
   ├── Quotes             pluggable price/quote providers (URLSession)
   ├── Intelligence       Apple Intelligence (FoundationModels) features (§11)
   │                      PDF text/OCR extraction · statement/invoice/dividend
   │                      readers · categoriser · budget advisor · forecast outlook
   │
   ├── Persistence        ★ native file format: open/save/lock
   │     ├── FinvestLensDocument   lifecycle, dirty-tracking, autosave
   │     ├── FileLock              NAS-safe advisory locking (§6)
   │     └── SQLiteDocumentStore   GRDB schema + snapshot read/write
   │
   └── Engine  ★ pure Swift, no persistence/UI deps
        ├── Money           Decimal-based amounts + Commodity
        ├── model           Account · Split · Transaction · Commodity · Book
        ├── PriceDB · Lot · Policy · CapGains
        ├── ScheduledTxn · Recurrence · Budget
        ├── Scrub           integrity/validation
        └── Core            GncGUID · KvpFrame · Query
```

Dependencies point **downward only**. `Engine` builds and tests with nothing above it. The UI and interchange layers talk to the engine's in-memory model; the `Persistence` layer persists that model to the native file.

---

## 3. The source-of-truth model

FinvestLens follows a **check-out → edit locally → explicit save** document model:

1. **Open** a `.finvestlens` document → acquire the lock (§6) → copy it to a **local working copy** (§6) → open the SQLite store on the *local* copy → materialize the observable in-memory **`Book`**. Retain a pristine snapshot of the opened state for Revert.
2. **Edit** against the in-memory model + local working copy (the working session). The engine `Book` is a plain (non-observable) model; the UI binds via **Observation on `AppModel`** (FeatureUI), which snapshots derived state after each mutation. Edits accumulate **locally only** — the document on the share is untouched.
3. **Write-back is explicit.** The local working copy is flushed back to the document location (atomically, under lock; §6.2) **only** on:
   - **File ▸ Save** (⌘S),
   - **Autosave** (as built: a fixed 5-minute interval while dirty; a user-configurable/disable setting is future work), or
   - **automatic save on switch/close/quit** (switching books, Close Book, and ⌘Q save first — failures surface and abort the switch/quit).

   There is **no continuous background sync** to the share.
4. **Discard / Revert.** Because the share only changes on an explicit save, the user can **abandon a working session**: **closing without saving** (or **File ▸ Revert**) discards unsaved changes and the on-share document reflects only the last save. The retained opened-state snapshot enables **Revert to the version that was opened**, even if autosave has run since.
5. **Close** → (prompt to save if dirty) → release the lock → drop the working copy (kept briefly only for crash recovery).

This keeps the engine free of persistence concerns, gives SQLite's scalability for large books, sidesteps the hazards of running SQLite directly over SMB/NFS, and — crucially — makes every write to shared storage a **deliberate, discardable** act.

---

## 4. Technology decisions at a glance

| Concern | Decision | Alternatives rejected | ADR |
|---|---|---|---|
| Money arithmetic | **Swift-native `Foundation.Decimal`**, wrapped in a `Money` type | hand-written rational (GnuCash parity); `Double`; BigInt/rational libs | §5.1 |
| Numeric fidelity vs GnuCash | **Good-enough**; tests tolerate rounding | bit-exact `gnc_numeric` port | §5.1 |
| Native file format | **Single SQLite file** (`.finvestlens`) via **GRDB** | SwiftData store; flat compressed file; file bundle | §5.2 |
| Persistence framework | **GRDB** (SQLite) behind `Repository` protocols | SwiftData; Core Data; Realm | §5.2 |
| Source of truth | **In-memory `Book`** + local working copy; document written back **only on explicit Save/autosave** (sessions are discardable) | SwiftData-managed context; direct-on-NAS SQLite; continuous auto-sync | §3, §5.2 |
| NAS concurrency | **App-level lock file + heartbeat + local copy + explicit atomic write-back** | trusting SQLite/POSIX locks over network | §6 |
| Coordinated file IO | **`NSFileCoordinator` / `NSFilePresenter`** | raw `FileManager` writes | §6 |
| GnuCash interoperability | **Import/export interchange** (XML), not the store | GnuCash XML as save format | §5.3 |
| Object identity | **Custom `GncGUID`** (32-hex, no dashes) for imported data | `Foundation.UUID` string form | §5.4 |
| Extensible metadata | **`KvpFrame`** value type, stored as JSON column | dropping unknown slots | §5.4 |
| Object framework | **Swift protocols + Observation** (replaces QOF) | porting QOF/GObject | §5.5 |
| Reports rendering | **Swift compute + Swift Charts** | Guile/HTML/WebKit | §5.6 |
| Quotes | **URLSession + pluggable providers** | Finance::Quote (Perl) | §5.7 |
| Sync | **File-level (iCloud Documents / Files / NAS)** | SwiftData+CloudKit | §8 |
| Tests | **Swift Testing** + tolerant comparisons + fixtures | XCTest-only; exact-match | §7 |

---

## 5. Key decisions — options and rationale

### 5.1 Money arithmetic — Swift-native `Decimal`

**Context.** Native-first (P1) and good-enough fidelity (P3) supersede the earlier goal of matching GnuCash's `gnc_numeric` exactly. We need a correct, native, decimal money type; small divergences from GnuCash's rounding are acceptable.

**Options.** (1) **`Foundation.Decimal`** — native base-10, 38 significant digits, value type, `Codable`. (2) Hand-written `Int64`/`Int128` rational to mirror GnuCash — rejected: violates native-first, and we no longer need bit-parity. (3) `Double` — rejected: binary rounding error. (4) BigInt/rational packages — rejected: non-native dependency for precision we don't require.

**Decision → `Foundation.Decimal`**, wrapped in a `struct Money { var amount: Decimal; var commodity: Commodity }`. Rounding uses `Decimal`'s `NSDecimalRound` with banker's/half-up rounding to the commodity's fraction (e.g. 2 dp for most currencies). Share quantities and prices are `Decimal`. Transaction balancing sums `Decimal`s and rounds to the transaction currency's scale; a residual within one minor unit is treated as balanced (an explicit imbalance beyond that is surfaced, not hidden).

**Rationale.** `Decimal` is the idiomatic Apple money type, exact for decimal values within range, and free of binary-float error — sufficient for double-entry bookkeeping. We drop the `Int128`/vector-conformance machinery entirely. Where GnuCash used odd denominators (e.g. 1/3-share fractions), `Decimal` rounds to 38 digits; per P3 this is acceptable and tests are written with tolerances.

> ADR-1: Money = `Decimal` wrapped in `Money`. No bit-exact GnuCash parity; tests tolerate rounding.

### 5.2 Native file format & persistence — SQLite via GRDB, SwiftData dropped

**Context.** The app must open and save its **own** file, that file may live on a **NAS**, and it must scale to 100k+ transactions (NFR-02). SwiftData's store is an app-container SQLite database not meant to be treated as a portable, user-placed, cross-machine-locked document, and SwiftData offers no story for network-share locking.

**Options.**
1. **GRDB (SQLite) single file** — a real, portable SQLite database as the document; fast, incremental, mature; full control over schema, migrations, journaling, and locking.
2. **SwiftData** — native and SwiftUI-friendly, but not designed for user-placed documents on network shares; multi-file store (`.sqlite`/`-wal`/`-shm`); no locking control. Rejected given P2/P6.
3. **Flat compressed snapshot** (whole book in RAM, atomic whole-file save) — simplest and very NAS-safe, but full rewrite per save and whole book in memory; rejected for scale.
4. **File package/bundle** — multi-file semantics complicate atomic network writes; rejected.

**Decision → a single SQLite file (`.finvestlens`) managed by [GRDB](https://github.com/groue/GRDB.swift)**. SwiftData is **not** used.

> **As built:** the store uses **whole-book snapshot semantics** — `read()` materializes the full graph and `write()` rewrites all tables in one transaction (a hybrid of options 1 and 3: SQLite file format, snapshot IO). This is simple and NAS-safe; incremental per-row persistence remains an optimization for the deferred 100k-txn perf validation to justify.

- **UTI / document type:** `com.hellotham.finvestlens.document` conforming to `public.database`; extension `.finvestlens`.
- **Schema & migrations:** GRDB `DatabaseMigrator`, versioned; a `meta` table records the app/schema version and a monotonically increasing **change counter**. Conflict detection as built uses a **SHA-256 file fingerprint** of the shared document (the counter is informational).
- **Journaling:** the working copy uses GRDB's default `DatabaseQueue` (rollback journal), so the artifact written back to the NAS is inherently a single self-contained file; a WAL + `wal_checkpoint(TRUNCATE)` pipeline remains an option if the deferred perf validation demands it (OD-3).
- **Document lifecycle:** a custom document controller (not SwiftUI `FileDocument`/`ReferenceFileDocument`, which assume whole-file snapshots) manages open/lock/copy/save/close so we can work against a live database.

**Rationale.** GRDB gives a genuine portable single-file database — ideal as a document — with the maturity and speed SwiftData lacks at scale, and the low-level control (journaling, checkpointing, coordinated IO) required to be safe on a NAS. The `Repository` abstraction (P4) keeps the engine and UI ignorant of GRDB.

> ADR-2: The document is one SQLite file via GRDB; SwiftData dropped; repositories abstract the store.

### 5.3 GnuCash interoperability — interchange only

**Context.** With our own native format, GnuCash's XML is no longer our store; it is an **import/export** path (PRD `FR-IMP-*`, `FR-EXP-*`).

**Decision.** Keep the XML codec in the `Interchange` layer: Foundation `XMLParser` (SAX, streaming) to read, a hand-written streaming writer to write. **As built, the gzip container is implemented natively** over Apple's Compression framework (a small header/trailer wrapper around raw DEFLATE) — no third-party gzip package is used. Round-trip fidelity is still a goal for supported objects, but **arithmetic differences from `Decimal` rounding are tolerated** (P3). Preserve GUIDs and KVP slots (§5.4) so re-export stays faithful.

> ADR-3: GnuCash XML is interchange (import/export), read via `XMLParser`, gzip via a zlib wrapper.

### 5.4 Identity & extensible metadata (for imported GnuCash data)

- **`GncGUID`** — a value type wrapping 16 bytes with GnuCash's exact **32-hex, no-dashes** encoding, so imported objects re-export with identical ids. Native objects created in FinvestLens may use `UUID` internally, but anything imported/exported through GnuCash XML preserves its `GncGUID` verbatim. Never round-trip through `Foundation.UUID`'s dashed string.
- **`KvpFrame`** — a recursive `[String: KvpValue]` value type covering GnuCash slot types (`int64, double, decimal, string, guid, gdate, timespec, frame, list`). Stored as a **JSON blob column** on the owning row. On import, **all** slots (including unrecognized keys) are retained and re-emitted on export, protecting round-trip fidelity.

> ADR-4: `GncGUID` + `KvpFrame` preserve imported identity/metadata; slots stored as JSON, never dropped.

### 5.5 Replacing QOF

QOF's guarantees are provided natively rather than ported: identity → Swift type + id; `QofBook`/collections → `Book` aggregate + repository fetches; `QofBackend` → `Repository` (GRDB) + XML codec; `QofQuery` → Swift predicates / GRDB query interface; class registration → protocols + generics; event bus → Observation/Combine; GObject refcount → ARC + value semantics.

> ADR-5: QOF is replaced by Swift protocols, GRDB, and Observation — not ported.

### 5.6 Reports — compute in Swift, render natively

Port each GnuCash report's **computation** (account/date selection, roll-ups, multi-currency) into Swift services over the engine; **discard** the Scheme/HTML/eguile/WebKit presentation and render with **SwiftUI + Apple Swift Charts** (`FR-RPT-03`), PDF via the platform. Core reports (Balance Sheet, Income Statement, Net Worth, Transaction Report, Cash Flow) in P4; investment reports in P5.

> ADR-6: Report logic → Swift services; rendering → Swift Charts/SwiftUI.

### 5.7 Quotes and exchange rates

GnuCash shells out to the Perl **Finance::Quote**; FinvestLens replaces it with a **native, pluggable provider layer** over `URLSession` + `Codable`. Two capabilities matter beyond "latest price": **historical backfill** (populate `PriceDB` across a date range) and **delisted securities** (prices for tickers no longer trading).

**Protocol.**

```swift
protocol QuoteProvider {
    var id: String { get }                     // "yahoo", "eodhd", "alphavantage", …
    var requiresAPIKey: Bool { get }
    var capabilities: QuoteCapabilities { get } // latest / historical / delisted / fx / search
    func latest(_ symbols: [SecuritySymbol]) async throws -> [Quote]
    func history(_ symbol: SecuritySymbol, range: DateInterval, interval: BarInterval) async throws -> [PricePoint]
    func search(_ query: String) async throws -> [SecurityMatch]   // optional
}
```

Results are written into `PriceDB` (`FR-INV-03`, `FR-CUR-04`); users pick a default/fallback order and can refresh on demand or on a schedule.

**API-key management.** Keyed providers store their key in the **Keychain** (never in the document, never in plists). The user enters keys in Settings; per the safety rules the *user* enters credentials — the app never solicits them from observed content. Requests go **directly** from the device to the provider over HTTPS.

**Providers shipped/adapters.**

| Provider | Key? | Latest | Historical | Delisted | Notes |
|---|---|---|---|---|---|
| **Yahoo (yfinance-like)** | **No** | ✓ | ✓ | partial | Native client for Yahoo's public JSON endpoints (see below). Default keyless option. |
| **EODHD** | Yes | ✓ | ✓ (30+ yr) | **✓** | [eodhd.com](https://eodhd.com/); historical EOD for **delisted** tickers (`delisted=1` on the Exchanges API + EOD endpoint) — the reason it's a first-class provider. Free tier: 20 calls/day, US, last year. |
| **Alpha Vantage** | Yes | ✓ | ✓ | – | [alphavantage.co](https://www.alphavantage.co/); free JSON. |
| **Finnhub** | Yes | ✓ | ✓ | – | JSON; generous free tier. |
| **Twelve Data** | Yes | ✓ | ✓ | – | JSON. |
| **Stooq** | No | – | ✓ (CSV) | partial | Keyless CSV EOD fallback. |

The list is extensible; adding a provider is a new `QuoteProvider` conformance.

**The "yfinance-like" Yahoo provider.** A native reimplementation of the approach used by [ranaroussi/yfinance](https://github.com/ranaroussi/yfinance) — **no API key**, hitting Yahoo's unofficial public endpoints:

- **History / OHLCV + dividends + splits:** `GET https://query1.finance.yahoo.com/v8/finance/chart/{symbol}?period1=…&period2=…&interval=1d&events=div,splits` — the chart endpoint generally needs **no crumb**, so historical backfill is straightforward.
- **Latest quote / fundamentals:** `v7/finance/quote` and `v10/finance/quoteSummary` — these now require a **cookie + crumb**. The client fetches a session cookie, then `GET /v1/test/getcrumb`, and appends `&crumb=…`. An EU-consent variant is handled if needed.
- **Symbol search:** `v1/finance/search?q=…`.
- Parsed with `Codable`; ret/backoff and rate-limit friendliness built in.

> **Legal/ToS note.** The Yahoo endpoints are unofficial and **not affiliated with or endorsed by Yahoo**; this provider is for personal/research use, mirroring what Finance::Quote/yfinance already do. Keyed providers (EODHD, etc.) are the sanctioned path for redistribution or heavier use. The UI surfaces this and lets users choose their provider accordingly.

> ADR-7: Native pluggable `QuoteProvider`s over URLSession — a keyless **yfinance-like Yahoo** client plus keyed providers (**EODHD** for delisted/deep history, Alpha Vantage, Finnhub, Twelve Data), with **historical backfill**, keys in Keychain, and user-selectable default/fallback.

### 5.8a Bank/financial file import — CSV, QIF, OFX/QFX (native)

**Context.** CSV, QIF, and OFX/QFX import are **core features** (PRD `FR-XIO-01/02/03`), not afterthoughts — they are how most users get bank/card/brokerage data in. They are **reimplemented natively in Swift**, not ported from GnuCash's GTK importers. Research finding: a good Swift **CSV** package exists, but there is **no Swift package for QIF or OFX/QFX** — mature parsers live in Python/JS/Ruby/.NET and serve as *format specifications*, not dependencies.

**Design.** A small `ImportParser` protocol yields a normalized `[StagedTransaction]` (date, amount, payee, memo, ref, optional splits/security/action), which flows into the shared **Import Matcher** (`FR-XIO-05`) for duplicate detection and destination-account assignment — one matcher, many front-end parsers.

| Format | Approach | Package / basis |
|---|---|---|
| **CSV** | **Custom Swift parser** (as built): RFC-4180-style with a configurable column mapping in the import UI. Saved mapping profiles (`FR-XIO-08`) are future work. | Hand-written; CodableCSV remains an option if needs outgrow it. |
| **QIF** | **Custom Swift parser.** QIF is a simple line-oriented format: single-letter tag per line (`D` date, `T`/`U` amount, `P` payee, `M` memo, `L` category/transfer, `N` number/action, `C` cleared, `S/E/$` splits), records terminated by `^`, section headers like `!Type:Bank`, `!Account`, `!Type:Invst`. No package needed. | Spec/oracles: [Wikipedia QIF](https://en.wikipedia.org/wiki/Quicken_Interchange_Format), [Quiffen (Py)](https://quiffen.readthedocs.io/), [hazzik/qif (.NET)](https://github.com/hazzik/qif). |
| **OFX / QFX** | **Custom Swift parser** handling both flavors: strip the OFX header block, then **OFX v2 (XML)** → reuse our `XMLParser`; **OFX v1 (SGML)** → a tolerant tokenizer that auto-closes value-only leaf tags (OFX v1 omits closing tags) to normalize into the same element tree. Handles bank (`STMTRS`), credit-card (`CCSTMTRS`), and investment (`INVSTMTRS`) statements; QFX is OFX plus Quicken extensions. | Spec/oracles: [ofxtools (Py)](https://github.com/csingley/ofxtools), [ofx-js](https://github.com/bradenmacdonald/ofx-js), [salt-parser (Ruby)](https://github.com/saltedge/salt-parser). |

**Why custom for QIF/OFX.** No maintained Swift implementations exist; both formats are small and well-documented; owning the parsers avoids a non-native/unmaintained dependency (Principle P1) and lets all three share one staging model and matcher. The battle-tested libraries in other languages are used as **conformance references and test-fixture generators**, not linked code.

> ADR-7a: CSV/QIF/OFX are native, core importers over a shared `ImportParser` → Import Matcher pipeline. CSV uses CodableCSV; QIF and OFX/QFX are hand-written (no Swift package exists), specced against mature non-Swift parsers.

---

## 6. Native file format on a NAS — locking & write safety

Running SQLite **directly** over SMB/NFS is unsafe: network filesystems implement POSIX/byte-range locking incompletely, and WAL/shared-memory files misbehave. SQLite's own guidance is to avoid network filesystems. So we do **not** rely on SQLite/OS locking across the network. Instead:

### 6.1 Application-level lock (single-writer across machines)

Modeled on GnuCash's `.LCK` approach, hardened:

- Beside `Book.finvestlens` we create **`Book.lock`** (same base name, different extension — required for the macOS sandbox related-item grant, kept for a future sandboxed build) whose contents are JSON: `{ host, user, instanceID, pid, acquiredAt, heartbeatAt }`.
- **Acquire on open** using an **atomic create-if-absent** (`.withoutOverwriting`). All lock IO goes through **`NSFileCoordinator`** with a related-item presenter.
- If the lock exists and its `heartbeatAt` is **fresh**, the document is in use elsewhere → the open fails showing the holder; if the heartbeat is **stale** (> 90 s), the UI offers **Break Lock and Open**. (An Open-Read-Only mode is not in 1.0.)
- **Heartbeat:** while open, `heartbeatAt` is refreshed every 25 s (a background task in `AppModel`), and on every save. This distinguishes a live holder from a crashed one.
- **Release on close;** crash recovery relies on stale-heartbeat detection.
- **Lockless fallback (iOS providers).** Where the sibling `.lock` cannot be
  created — an iOS file-provider grant (iCloud Drive, Box, Dropbox via the
  Files picker) covers only the document, and the related-item mechanism is
  macOS-only — the document still opens, with `advisoryLockHeld == false`;
  saves remain guarded by the §6.2 fingerprint conflict check. A **live**
  lock held by someone else still refuses the open.

### 6.2 Local working copy + atomic write-back

To get SQLite's speed/scale without trusting it over the network, and to make write-back an explicit, discardable act:

1. **On open** (after acquiring the lock): copy `Book.finvestlens` from the share to a **local working copy** (a per-session file under the app's temporary directory); note the source's SHA-256 fingerprint, and keep a **pristine opened snapshot** for Revert.
2. **Edit** against the local SQLite (WAL, fast, reliable local semantics). Nothing is written to the share during editing.
3. **Write-back happens only on explicit Save, autosave, or save-on-switch/close/quit** (lock still held): the consolidated single file is written back to the share atomically (replace-item semantics) under `NSFileCoordinator`, and the `meta` change counter is bumped. Autosave runs on a fixed 5-minute interval while dirty (a configurable/disable setting is future work).
4. **Discard / Revert:** closing without saving (or File ▸ Revert) discards the working copy's unsaved changes; the share is left as it was at the last save. Reverting to the pristine opened snapshot restores the session's start state.
5. **Conflict defense in depth:** before overwriting, re-read the document's SHA-256 fingerprint on the share; if it changed unexpectedly (someone bypassed the lock, or an out-of-band edit), **do not clobber** — the save throws a conflict which the UI surfaces.
6. **On close:** if dirty, prompt to Save or Discard; then release the lock and drop the working copy (retained briefly only for crash recovery).

For **genuinely local volumes** (not a network share), the working-copy hop can be skipped (direct mode) as an optimization; the explicit-save/discard semantics and locking still apply.

### 6.3 iCloud / Files integration

Because the document is a file, sync is **file-level**: place it in iCloud Documents or any Files-accessible location. We implement **`NSFilePresenter`** to react to external changes and use **`NSFileVersion`** for conflict resolution, consistent with the NAS write-back path. (This replaces the earlier SwiftData+CloudKit plan; `FR-PLT-02` becomes file-based sync.)

Cloud specifics (verified 14 Jul 2026 on Box Drive and iCloud Drive, incl. an evicted/dataless file):

- **Dataless placeholders.** The open-time copy-in and every fingerprint go through a **coordinated read**, which downloads and materialises a not-yet-local file (iCloud eviction, File Provider online-only) before it is touched.
- **iOS security scope.** Books picked on iOS are security-scoped; `AppModel` holds the grant for the whole session (saves write back to the shared file) and stores a **bookmark** per recent so Open Recent can regain the grant after a relaunch.
- **macOS provider drives** (`~/Library/CloudStorage`: Box, Dropbox, OneDrive) behave like local folders for the unsandboxed app; the sibling `.lock` syncs through the provider and extends single-writer protection across machines (heartbeat staleness is approximate under sync latency).

> ADR-8: NAS safety = app-level lock file + heartbeat + local working copy + **explicit (Save/autosave) coordinated atomic write-back** + discardable sessions, never direct SQLite-over-network.

---

## 7. Testing architecture

1. **Money/rounding** — tests assert correctness of `Money`/`Decimal` operations and balancing with **explicit tolerances**; parity with GnuCash is checked only approximately (P3).
2. **Round-trip interchange** — a corpus of `.gnucash` files under `Tests/Fixtures`; import→export→re-import compares **object graphs** with numeric tolerance and exact GUID/slot preservation (`FR-EXP-02` for structure; amounts within tolerance).
3. **Invariants** — every persisted transaction balances within tolerance (`FR-ENG-06`); `Scrub` reports nothing on a clean import.
4. **Locking, write-back & discard** — simulate concurrent openers (two lock acquirers), stale-lock breaking, mid-save crash (working copy intact, document untouched), conflicting external writes, and **discard/revert** (edit → close without saving → assert the on-disk document is byte-unchanged from the last save; Revert restores the opened snapshot). Assert the document is never corrupted or silently clobbered.
5. **Performance** — a synthetic 100k-transaction document gates open/scroll/import/save against NFR-02.

Framework: **Swift Testing** for new tests; XCTest where needed for UI/perf harnesses.

---

## 8. Concurrency, sync, and cross-platform

- **Engine** is synchronous/deterministic. **IO is async at the edges** (open/copy, save/write-back, import/export, quotes) with progress reporting; the UI stays responsive.
- **GRDB** access uses its `DatabaseQueue`/`DatabasePool` (serialized writes); the UI reads via observations.
- **Sync** is file-level (§6.3) — iCloud Documents, Files, or the NAS — not SwiftData/CloudKit.
- **One shared codebase.** `Engine`/`Document`/`Interchange`/`Reports`/`Quotes` are platform-agnostic. `FeatureUI` adapts: `NavigationSplitView` on macOS/iPadOS, compact stacks on iOS. macOS maps GnuCash-style menus to a native menu bar.

---

## 9. Recommended Swift packages

| Package | Use | Phase | License | Notes |
|---|---|---|---|---|
| [groue/GRDB.swift](https://github.com/groue/GRDB.swift) | **Native document store** (SQLite) | P1 | MIT | The **only** external dependency in 1.0. |

**As built, went native instead of a package:** the **gzip** container (small header/trailer over Apple Compression's raw DEFLATE) and the **CSV** parser (hand-written, mapping UI on top) — GzipSwift/swift-gzip and CodableCSV were evaluated but not needed.

**Hand-written, no package (none exists for Swift):** **QIF** and **OFX/QFX** parsers (`FR-XIO-01/02`), specced against mature Python/JS/Ruby parsers (§5.8a). OFX v2 reuses `XMLParser`.

**Native / no dependency:** money (`Decimal`), XML read (`XMLParser`), gzip (Compression), CSV/QIF/OFX parsers, charts (Swift Charts), coordinated file IO (`NSFileCoordinator`/`NSFilePresenter`/`NSFileVersion`), tests (Swift Testing), quotes (`URLSession`). **Removed vs v0.1:** SwiftData, the `Int128`/BigInt numeric machinery, GzipSwift, CodableCSV.

---

## 10. Open decisions to revisit

| # | Question | Trigger |
|---|---|---|
| OD-1 | Heartbeat interval & stale-lock threshold | Field-test on real SMB/NFS latency |
| OD-2 | Direct-mode vs always-working-copy on local volumes | Perf vs safety measurement |
| OD-3 | WAL vs DELETE journal for the working copy | Crash-recovery testing (§7.4) |
| OD-4 | `Decimal` rounding mode per commodity (half-up vs banker's) | Compare against common statements |
| OD-5 | Which quote providers ship by default | Free-tier/licensing review (P5) |
| OD-6 | Target GnuCash XML schema version for export | Confirm vs current stable GnuCash (v5-era) |

---

## 11. Apple Intelligence integration (Intelligence package)

Added post-1.0. All features run on the **on-device** Foundation Models
framework (macOS 26 / iOS 26) — no financial data ever leaves the device — and
follow one contract:

1. **The model proposes; deterministic code disposes.** Model output is typed
   (`@Generable` guided generation, greedy sampling for extraction), parsed
   tolerantly (`IntelligenceParsing`), resolved against the real chart of
   accounts (`AccountNameMatcher`), and cross-checked arithmetically (statement
   signs re-derived from the running balance column; invoice line sums
   reconciled against the printed total). Only reviewed results mutate the book.
2. **Availability-gated.** `IntelligenceAvailability` probes
   `SystemLanguageModel.default`; menus disable (with the reason as a tooltip)
   when Apple Intelligence is off, and every entry point degrades gracefully.
   Guardrail refusals (`.refusal`/`.guardrailViolation`) surface a friendly
   message; the budget advisor retries with simplified phrasing and finally
   falls back to a deterministic average-based plan.
3. **Small context, chunked work.** PDF pages are extracted via PDFKit with a
   geometric reflow (rows rebuilt from per-character bounds — content-stream
   order scrambles tables) and a Vision-OCR fallback for scans; each page or
   batch is one fresh session.

| Feature | ID | Flow |
|---|---|---|
| PDF statement import | FR-AI-01 | `StatementExtractor` → `StagedTransaction` → existing ImportMatcher/review; duplicate rows can mark the matched register split cleared (light reconciliation) |
| Auto-categorisation | FR-AI-02 | `TransactionCategorizer` fills gaps after rules → history → heuristics, in import review and the Auto-Categorise panel (Imbalance/Orphan splits) |
| Invoice splitting | FR-AI-03 | `InvoiceAnalyzer` line items → categorised splits in the transaction editor ("Split from Invoice…") |
| Dividend statements | FR-AI-04 | `DividendExtractor` (franked/unfranked/franking credits) → reviewed booking incl. gross-up (Income:Dividends:Franking Credits ↔ Assets:Franking Credits Receivable) |
| Budget suggestion | FR-AI-05 | Deterministic 6-month spending stats → `BudgetAdvisor` → reviewed per-line apply |
| Forecast outlook | FR-AI-06 | Computed `cashFlowForecast` facts → `ForecastNarrator` headline + insights in the Cash Flow report |
| Smart Import (multi-PDF) | FR-AI-07 | `DocumentClassifier` triages each PDF (model + keyword fallback), then routes: statements → FR-AI-01 review; dividend statements → **verified against the register** (matching deposit found, franking credits checked, one-click fix rebuilds the gross-up in place, preserving the cash split's reconcile state); invoices → **matched to their transaction** (amount + date-window, banks post late) then split by line items and re-dated to the invoice date. Match results refresh as earlier documents in the batch are applied. |
| Document links | FR-AI-08 | Applied dividend statements and invoices are copied into the document folder (Settings ▸ Documents; default: the book's folder — GnuCash's association "path head") and linked to their transaction via the `assoc_uri` KVP slot as a relative path (identical files reused, name collisions uniqued). Register context menu → "Open Linked Document". |

**Dual dates (FR-AI-07).** When Smart Import adopts a document's true economic
date, the bank's posted date moves to a preserved KVP slot
(`Transaction.statementDate`, `finvestlens/statement-date`) — matching (the
import matcher's duplicate detection and Smart Import's own windows) considers
*both* dates, so re-importing the same bank statement never duplicates a
re-dated transaction. The slot lives in the native document; GnuCash XML
export simply carries the adjusted `datePosted` (no schema breakage — GnuCash
sees the economic date).

**Document links (FR-AI-08).** `Transaction.documentLink` uses GnuCash's own
slot key (`assoc_uri`), and the XML exporter/importer round-trips it in
`trn:slots`, so links attached in FinvestLens open in GnuCash and vice versa.
Resolution follows GnuCash semantics: absolute paths and `file://` URIs open
as-is; anything else is relative to the configured document folder (or the
book's folder when unset).

Testing: deterministic parts are unit-tested; `LiveModelTests` exercises the
real on-device model end-to-end (PDF fixtures rendered in-test) and self-skips
where Apple Intelligence is unavailable, keeping CI deterministic.

---

## 12. References

**Persistence / SQLite**
- [groue/GRDB.swift](https://github.com/groue/GRDB.swift) · [Core Data vs SwiftData 2025](https://distantjob.com/blog/core-data-vs-swiftdata/) · [SwiftData slow with large data (Apple Forums)](https://developer.apple.com/forums/thread/740517) · [SwiftData vs Realm perf](https://www.emergetools.com/blog/posts/swiftdata-vs-realm-performance-comparison)
- SQLite over network filesystems (avoid) — https://www.sqlite.org/whentouse.html · `NSFileCoordinator` — https://developer.apple.com/documentation/foundation/nsfilecoordinator

**Money**
- `Foundation.Decimal` — https://developer.apple.com/documentation/foundation/decimal

**XML / compression**
- Foundation `XMLParser` (native SAX) · [1024jp/GzipSwift](https://github.com/1024jp/GzipSwift) · [mihai8804858/swift-gzip](https://github.com/mihai8804858/swift-gzip)

**Quotes / market data**
- Keyless (yfinance-like) — [ranaroussi/yfinance](https://github.com/ranaroussi/yfinance) (approach reference); Yahoo endpoints `query1/query2.finance.yahoo.com`
- Keyed — [EODHD](https://eodhd.com/) ([delisted data](https://eodhd.com/financial-apis/delisted-stock-companies-data) · [historical for delisted](https://eodhd.com/financial-academy/financial-faq/historical-stock-prices-for-delisted-companies)) · [Alpha Vantage](https://www.alphavantage.co/) · [Finnhub / free APIs overview](https://dev.to/williamsmithh/top-5-free-financial-data-apis-for-building-a-powerful-stock-portfolio-tracker-4dhj)

**Import formats (P4)**
- CSV — [dehesa/CodableCSV](https://github.com/dehesa/CodableCSV) · [yaslab/CSV.swift](https://github.com/yaslab/CSV.swift)
- QIF (custom; specs) — [Wikipedia QIF](https://en.wikipedia.org/wiki/Quicken_Interchange_Format) · [Quiffen](https://quiffen.readthedocs.io/) · [hazzik/qif](https://github.com/hazzik/qif)
- OFX/QFX (custom; specs) — [csingley/ofxtools](https://github.com/csingley/ofxtools) · [bradenmacdonald/ofx-js](https://github.com/bradenmacdonald/ofx-js) · [saltedge/salt-parser](https://github.com/saltedge/salt-parser)

**Project docs** — [PRD](prd.md) · [Porting Strategy](porting.md) · [README](../README.md) · [LICENSE](../LICENSE)

> All recommended dependencies are MIT-licensed (GPLv3-compatible). FinvestLens is licensed GPLv3 and is not affiliated with or endorsed by the GnuCash project.
