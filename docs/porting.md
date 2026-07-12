# FinvestLens — Porting Strategy

| | |
|---|---|
| **Document status** | Draft v0.2 |
| **Last updated** | 2026-07-12 |
| **Scope** | The *strategy* for reimplementing GnuCash as native Swift — what to port, rewrite, replace, or discard, and how. **The delivery schedule lives in the [Implementation Plan](plan.md).** |
| **Companions** | [PRD](prd.md) · [Architecture](architecture.md) · [Implementation Plan](plan.md) |
| **Upstream** | [github.com/Gnucash/gnucash](https://github.com/Gnucash/gnucash) (C/C++ engine + Guile/Scheme reports + GTK UI) |

---

## 1. Philosophy: a rewrite, not a transliteration

GnuCash is ~C/C++ built on **GLib/GObject** and the **QOF** (Query Object Framework), with reports written in **Guile Scheme** and a **GTK** UI. A line-by-line transliteration to Swift would import a foreign object model, manual reference counting, and framework idioms that fight the language. FinvestLens is therefore a **rewrite**:

- **Preserve the *semantics and the data*, not the code shape.** The double-entry model, the account/commodity/price/lot behavior, and the **GnuCash XML interchange format** must be reproduced faithfully — though money uses native `Decimal` and **exact arithmetic parity is a non-goal** (rounding differences are tolerated). See PRD `FR-EXP-02` (round-trip fidelity, structure exact / amounts within tolerance) and `FR-ENG-06` (double-entry invariant).
- **Write idiomatic Swift.** Value types and `struct`s where GnuCash uses GObject pointers; Swift protocols/generics where it uses QOF class registration; a **GRDB/SQLite store behind repository protocols** where it uses a QOF backend; native **`Decimal`** where it uses `gnc_numeric`; `async/await` and `Combine`/Observation where it uses GLib signals and event queues; `Foundation` where it uses GLib utilities.
- **Use the C++ source as the executable specification.** When behavior is subtle (rounding, lot cost-basis, SX recurrence, XML quirks), the upstream `.cpp` is the reference oracle — we port its *logic and test vectors*, not its structure.

**Guiding rule:** if a piece of GnuCash exists to serve GObject/GTK/Guile/SQL plumbing, we **replace** it with the native equivalent; if it encodes *accounting behavior or file semantics*, we **port** it faithfully.

---

## 2. Source-to-target decision map

Disposition legend: **Port** = reimplement behavior faithfully in Swift · **Refactor** = keep the logic, replace the presentation/framing · **Replace** = native Apple equivalent · **Discard** = not carried over. The **Phase** column is an indicative pointer; the authoritative schedule is the [Implementation Plan](plan.md).

| GnuCash area | Path | Disposition | Swift target | PRD refs | Phase |
|---|---|---|---|---|---|
| **Numeric type** (`gnc_numeric`) | `libgnucash/engine/gnc-numeric.*` | **Replace** | `Money` over native `Decimal` (no bit-parity; see §4.1) | FR-ENG-01 | P0 |
| **Core model** — Account/Transaction/Split | `engine/Account.cpp`, `Transaction.cpp`, `Split.cpp` | **Port** | Engine model types | FR-ENG-02..07 | P0 |
| **Commodities** | `engine/gnc-commodity.*` | **Port** | `Commodity`, `CommodityTable` | FR-ENG-08 | P0 |
| **Price database** | `engine/gnc-pricedb.*` | **Port** | `PriceDB` | FR-ENG-09 | P5 |
| **Lots + policy** (FIFO/LIFO) | `engine/gnc-lot.*`, `policy.*`, `cap-gains.*` | **Port** | `Lot`, cost-basis policy | FR-ENG-10, FR-INV-05 | P5 |
| **Scheduled txns** | `engine/SchedXaction.*`, `Recurrence.*`, `FreqSpec.*` | **Port** | `ScheduledTransaction`, `Recurrence` | FR-SCH-\* | P4 |
| **Budgets** | `engine/gnc-budget.*` | **Port** | `Budget` | FR-BUD-\* | P4 |
| **Data integrity** (Scrub) | `engine/Scrub*.cpp` | **Port** | Validation/repair services | FR-ENG-06, FR-IMP-08 | P1 |
| **Query** | `engine/Query.cpp`, `qofquery.*` | **Refactor** | Swift predicates / GRDB query interface | FR-REG-06 | P2 |
| **QOF object framework** | `engine/qof*.{h,cpp}` (instance, book, id/GUID, collection, class/object, event, kvp) | **Replace** (mostly) | Swift protocols + GRDB repositories + native GUID/KVP types + Observation | FR-DAT-\*, FR-ENG-11 | P0–P1 |
| **Business objects** | `engine/gnc{Customer,Vendor,Employee,Invoice,Entry,Job,Order,Owner,Address,BillTerm,TaxTable}.*` | **Port** (later) | Business model types | FR-BUS-\* | P7 |
| **Tax tables (TXF)** | `libgnucash/tax/` | **Port** (later) | Tax-table data + logic | FR-BUS-04 | P7 |
| **XML backend (read/write v2)** | `backend/xml/gnc-*-xml-v2.cpp`, `io-gncxml-v2.cpp`, `gnc-xml-helper.*` | **Rewrite** | Swift XML importer/exporter | FR-IMP-\*, FR-EXP-\* | P1/P3 |
| **XML v1 reader (legacy)** | `backend/xml/io-gncxml-v1.cpp` | **Port** (read-only, optional) | Legacy import path | FR-IMP-01 | later |
| **SQL / DBI backends** | `backend/sql/`, `backend/dbi/` | **Discard** | (FinvestLens has its own SQLite schema via GRDB — not GnuCash's) | NG1 | — |
| **QIF import** | `import-export/qif-imp/` | **Reimplement** (native; do *not* port GnuCash's) | Hand-written Swift QIF parser (no Swift pkg exists) | FR-XIO-01 | P4 |
| **OFX/QFX import** | `import-export/ofx/` (libofx) | **Reimplement** (native) | Hand-written Swift OFX parser: v2→`XMLParser`, v1→SGML normalizer (no Swift pkg exists) | FR-XIO-02 | P4 |
| **CSV import/export** | `import-export/csv-imp/`, `csv-exp/` | **Reimplement** (native) | Swift CSV via CodableCSV + mapping profiles | FR-XIO-03, -06, -08 | P4 |
| **Generic import matcher** | `import-export/import-backend.cpp`, `import-main-matcher.*`, `import-account-matcher.*`, `import-match-picker.*`, `import-pending-matches.*` | **Port** (logic) + rebuild UI | Swift match engine + SwiftUI matcher; shared by all importers | FR-XIO-05 | P4 |
| **AqBanking / MT940 / DTAUS / bi-import / log-replay** | `import-export/aqb/`, `bi-import/`, `customer-import/`, `log-replay/` | **Discard early** (revisit) | — | FR-XIO-04, -07 | later/won't |
| **Report engine** | `report/report-core.scm`, `trep-engine.scm`, `report-utilities.scm`, `commodity-utilities.scm` | **Refactor** (port calculation logic) | Swift report/query services | FR-RPT-\* | P4/P5 |
| **Report HTML/rendering** | `report/html-*.scm`, `eguile*.scm`, `stylesheets/`, `gnucash/html/` (WebKit) | **Replace** | SwiftUI views + Swift Charts | FR-RPT-03, -05 | P4 |
| **Standard reports** (~40) | `report/reports/standard/*.scm` | **Refactor** (subset) | Native reports (see §6) | FR-RPT-\* | P4/P5 |
| **Autofill / QuickFill** | `app-utils/QuickFill.*`, `gnc-*-quickfill.*` | **Port** (behavior) | Swift autocompletion model | FR-REG-04 | P2 |
| **Expression parser** | `app-utils/gnc-exp-parser.*`, `gfec.*` | **Port** | Swift formula evaluator (register/SX amounts) | FR-SCH-02 | P4 |
| **SX instance model** | `app-utils/gnc-sx-instance-model.*` | **Port** | SX instantiation/"since last run" | FR-SCH-03 | P4 |
| **Auto-clear** | `app-utils/gnc-autoclear.*` | **Port** | Reconciliation auto-clear | FR-REC-\* | P4 |
| **Formatting utils** | `app-utils/gnc-ui-util.*` | **Replace** | Foundation formatters (locale-aware) | NFR-06 | P2 |
| **Finance::Quote** | `libgnucash/quotes/`, `app-utils/gnc-quotes.*` (Perl subprocess) | **Replace** | Native pluggable `QuoteProvider`s: keyless yfinance-like Yahoo client + keyed providers (EODHD/delisted, Alpha Vantage, Finnhub); Keychain keys; historical backfill (Architecture §5.7) | FR-INV-03\* , FR-CUR-04 | P5 |
| **Prefs / GSettings / state** | `app-utils/gnc-gsettings.*`, `gnc-state.*`, `core-utils/` | **Replace** | `UserDefaults` / SwiftUI settings / Foundation | FR-COA-03 | P2 |
| **GTK UI** | `gnucash/gnome`, `gnome-utils`, `gnome-search`, `gtkbuilder/`, `ui/`, `*.css` | **Discard** | SwiftUI (rebuilt) | NG2 | all |
| **Register/ledger widget** | `gnucash/register/` (register-core, ledger-core) | **Refactor** (behavior only) | SwiftUI register (consult ledger-core for rules) | FR-REG-\* | P2 |
| **Language bindings** | `bindings/` (Python, SWIG/Guile) | **Discard** | (App Intents instead) | NG3 | — |
| **Module loader** | `libgnucash/gnc-module/` | **Discard** | Native Swift modules | — | — |

---

## 3. Target Swift architecture

```
┌──────────────────────────────────────────────────────────┐
│  UI  (SwiftUI, per-platform)   — rebuilt, not ported       │
├──────────────────────────────────────────────────────────┤
│  Reports  (Swift services + SwiftUI/Charts) — refactored   │
│  Import/Export  (Swift codecs) — rewritten                 │
├──────────────────────────────────────────────────────────┤
│  Document  (native .finvestlens SQLite via GRDB;           │
│            NAS locking + atomic write-back; GUID/KVP)       │
├──────────────────────────────────────────────────────────┤
│  Engine  (pure Swift, no UI/persistence deps) — ported     │
│    Money(Decimal) · Account · Transaction · Split · Commodity │
│    PriceDB · Lot/Policy · ScheduledTxn · Budget · Scrub    │
│    (Book, GUID, KVP, Query as Swift-native replacements)   │
└──────────────────────────────────────────────────────────┘
```

The **engine** is a standalone Swift module (no persistence, no SwiftUI — Foundation value types like `Decimal`/`Date` are fine) so it is unit-testable in isolation and reusable across platforms (PRD `FR-ENG-12`). The `Document`/GRDB layer wraps the engine; the engine never depends upward.

---

## 4. Key porting challenges and strategies

### 4.1 The numeric type — `gnc_numeric` → native `Decimal` `Money`

GnuCash stores every amount as an **exact rational** `{ int64 num; int64 denom; }` with explicit rounding and denominator policies. **FinvestLens does not port this.** Per the native-first / good-enough-fidelity direction (Architecture ADR-1), we use Swift-native **`Foundation.Decimal`**.

**Strategy:**
- Implement `struct Money { var amount: Decimal; var commodity: Commodity }`. `Decimal` is base-10, 38 significant digits, value-typed and `Codable` — exact for decimal money, free of binary-float error.
- Round to the commodity's fraction (e.g. 2 dp) via `NSDecimalRound`; balancing sums `Decimal`s and treats a residual within one minor unit as balanced.
- **We deliberately accept small divergences from GnuCash.** Where GnuCash used odd denominators (e.g. 1/3-share fractions), `Decimal` rounds; that is acceptable.
- **Testing:** assert `Money`/`Decimal` correctness with **tolerances**, not bit-for-bit parity against `gnc_numeric`. `gnc-numeric` test vectors may be used as *approximate* references only.

> This removes the earlier need for `Int128`/BigInt machinery entirely.

### 4.2 Identity — GUIDs

GnuCash gives every first-class object a **128-bit GUID**, serialized as **32 lowercase hex characters with no dashes** (not RFC-4122 formatting). Round-trip requires re-emitting the *exact same string*.

**Strategy:** a `GncGUID` type wrapping 16 bytes with GnuCash's hex encoding/decoding. Do **not** use `Foundation.UUID`'s default string form (dashed, uppercase). Store the canonical bytes; format on export to match GnuCash. Preserve imported GUIDs unchanged (PRD `FR-ENG-11`, `FR-IMP-06`).

### 4.3 KVP "slots" — lossless round-trip

QOF instances carry arbitrary **key-value frames** ("slots") — nested typed dictionaries used for everything from reconciliation dates to business links to features we don't model yet. Dropping unknown slots would break round-trip fidelity.

**Strategy:** a `KvpFrame` value type (recursively nested `[String: KvpValue]`, where `KvpValue` covers the GnuCash slot types: int64, double, numeric, string, guid, timespec, gdate, frame, list). Every model object carries an optional `KvpFrame`. On import, **retain all slots** — even unrecognized ones — and re-emit them on export. This is the backbone of `FR-IMP-06`/`FR-EXP-03`.

### 4.4 QOF → native Swift

QOF provides object identity, reflection/registration, a collection index, a pluggable backend, a query language, and an event bus. We do **not** port QOF as a framework; we provide its *guarantees* natively:

| QOF concept | GnuCash | FinvestLens |
|---|---|---|
| `QofInstance` | GObject + GUID + kvp + dirty flag | Swift model type + `GncGUID` + `KvpFrame` |
| `QofBook` | container of collections | `Book` aggregate root (in-memory; GRDB-backed) |
| `QofCollection` | per-type GUID index | GRDB repository fetch / in-memory index |
| `QofBackend` | XML/SQL persistence plugin | GRDB SQLite store (native format) + XML interchange codec |
| `QofQuery` | term-based query | Swift predicates / `FetchDescriptor` |
| `QofClass`/`QofObject` | runtime registration | Swift protocols + generics (compile-time) |
| `qofevent` | signal bus | Combine/Observation; GRDB value observation |
| memory | manual GObject refcount | ARC + value semantics |

### 4.5 Data integrity — Scrub

`Scrub*.cpp` repairs/validates books (balancing imbalances via an Imbalance account, fixing orphans, scrubbing lots/business links). This logic is **essential** and ports directly as validation services run after import (`FR-IMP-08`) and before commit (`FR-ENG-06`). It is not UI — pure model logic.

### 4.6 Concurrency & events

GnuCash uses GLib main-loop signals and a global engine-event queue. FinvestLens uses SwiftUI's observation, GRDB value observation, and `async/await` for long operations (open/save, import, quote fetch). The engine itself stays synchronous and deterministic; async lives at the persistence/IO/UI boundary.

---

## 5. Module-by-module notes

- **Engine (P0):** Start here. `Money`/`Decimal` first (everything depends on it), then `Commodity`, then `Account`/`Split`/`Transaction` with the balancing invariant, then `Book`. Port `Scrub` alongside. Golden test: construct transactions in code and assert balances (with tolerance).
- **XML backend (P1 import / P3 export):** The single most important interoperability component. Rewrite as a streaming Swift XML reader/writer that maps the GnuCash namespaces (`gnc:`, `act:`, `trn:`, `split:`, `cmdty:`, `price:`, `sx:`, `bgt:`, `book:`, and business `cust:`/`vendor:`/`invoice:`/… ). Handle gzip. Mirror `io-gncxml-v2.cpp`'s element order and the per-object `gnc-*-xml-v2.cpp` field mappings. Preserve slots and GUIDs. Build the round-trip test harness (`FR-EXP-02`) as soon as both directions exist.
- **app-utils (P2/P4):** Port `QuickFill` (autofill trie behavior), `gnc-exp-parser` (in-register formula math), `gnc-sx-instance-model` ("since last run" generation), `gnc-autoclear`. Replace formatting/prefs with Foundation/`UserDefaults`.
- **Bank/file import (P4, core):** CSV, QIF, and OFX/QFX are **reimplemented natively** — we do *not* port GnuCash's importers or link libofx. Custom Swift parsers (CSV via CodableCSV; QIF and OFX/QFX hand-written since no Swift package exists) each emit a normalized staging model into one shared **Import Matcher**. The matcher's account-guessing and duplicate heuristics (`import-backend.cpp`) are the one piece worth porting closely (`FR-XIO-05`); mature non-Swift parsers (ofxtools, Quiffen, salt-parser) are used as conformance references and fixture generators. See [Architecture §5.8a](architecture.md).
- **Business (P7):** Port the object graph (`gncInvoice` posting to A/R via lots and entries, terms, tax tables). This is deep; schedule after core is proven.

---

## 6. Reports: keep the logic, replace the presentation

GnuCash reports are Guile Scheme with two separable halves:

1. **Computation** — `report-core.scm`, `trep-engine.scm`, `report-utilities.scm`, `commodity-utilities.scm`, and each report's account-collection / date-range / multi-currency roll-up logic. **This is the valuable part** and is refactored into Swift services that query the engine.
2. **Presentation** — `html-table.scm`, `html-chart.scm`, `eguile*` templating, `stylesheets/`, and the WebKit `gnucash/html` renderer. **Discarded** and replaced by SwiftUI views and Swift Charts (`FR-RPT-03`), with PDF via the platform (`FR-RPT-05`).

**Approach:** treat each Scheme report as a spec. Reimplement its data pipeline in Swift (options → account/date selection → balance computation → rows/series), then render natively. Prioritize the core set (Balance Sheet, Income Statement/P&L, Net Worth, Transaction Report, Cash Flow) for P4; investment reports (Portfolio, Advanced Portfolio, Price Scatter, Investment Lots) for P5. The long tail (~40 standard reports) is ported opportunistically.

---

## 7. What we deliberately do not carry over

| Discarded | Why | Native replacement |
|---|---|---|
| GTK UI (`gnome*`, `gtkbuilder`, CSS, WebKit html) | Not native to Apple platforms (NG2) | SwiftUI |
| Guile/Scheme runtime & report rendering | Foreign runtime; not idiomatic | Swift + Swift Charts |
| SQL/DBI backends | FinvestLens has its own SQLite schema (NG1) | GRDB (own schema) |
| Finance::Quote (Perl subprocess) | External runtime dependency | Native pluggable `QuoteProvider`s (yfinance-like + keyed) |
| GObject/QOF framework plumbing | Replaced by Swift language features | protocols, generics, ARC, GRDB, Observation |
| Language bindings (Python/SWIG) | Out of scope (NG3) | App Intents / Shortcuts |
| `gnc-module` dynamic loader | Unneeded with native modules | Swift modules |
| AqBanking / online-banking DirectConnect | Heavy external dep; early **Won't** (`FR-XIO-07`) | (revisit later) |

---

## 8. Fidelity & testing strategy

Correctness is defined by matching GnuCash, so the port is validated against it:

1. **Numeric sanity (tolerant)** — assert `Money`/`Decimal` operations and balancing within tolerances; `gnc-numeric` vectors are approximate references only, not an exact-match gate (§4.1).
2. **Round-trip corpus** — maintain a set of real/sample `.gnucash` XML files (small → large, personal → business, multi-currency, investments). CI asserts import → export → re-import preserves structure/GUIDs/slots losslessly, with monetary amounts equal **within tolerance** (`FR-EXP-02`, NFR-08). Compare the parsed object graphs (and order-normalized XML for structure).
3. **Invariant checks** — every persisted transaction balances (`FR-ENG-06`); Scrub finds nothing to fix on a clean import (`FR-IMP-08`).
4. **Behavioral parity spot-checks** — for lots/cap-gains, SX recurrence, and report totals, compare FinvestLens output against GnuCash on the same input file.

**Using upstream as an oracle:** when a behavior is ambiguous, read the specific `.cpp`, and where practical run GnuCash (or its test suite) on a fixture to capture expected output, then encode it as a Swift test.

---

## 9. Risks specific to the port

| # | Risk | Mitigation |
|---|---|---|
| PR1 | Rounding divergence from GnuCash | Accepted by design (native `Decimal`, good-enough fidelity); tests use tolerances, not bit-parity. |
| PR2 | XML round-trip loses slots/unknown elements | First-class `KvpFrame` preservation + passthrough of unrecognized elements; compare object graphs, not just re-render. |
| PR3 | GUID formatting mismatch (dashes/case) | Custom `GncGUID` codec; never rely on `UUID` string form. |
| PR4 | Report logic entangled with Scheme HTML | Separate computation from presentation per report; port only the pipeline. |
| PR5 | Business/lot/cap-gains subtlety | Port `policy.*`/`cap-gains.*`/`ScrubBusiness` closely with fixtures; schedule late (P5/P7) after core is proven. |
| PR6 | Scale (100k+ txns) and NAS write-safety | GRDB scales well; benchmark + load-test on a real network share in P1; balance caching; local working copy + atomic write-back (Architecture §6). |

---

## 10. References

- Upstream source — https://github.com/Gnucash/gnucash
  - Engine — `libgnucash/engine/` (`gnc-numeric`, `Account`, `Transaction`, `Split`, `gnc-commodity`, `gnc-pricedb`, `gnc-lot`, `policy`, `cap-gains`, `SchedXaction`, `Recurrence`, `gnc-budget`, `Scrub*`, `qof*`, `gnc*` business objects)
  - XML backend — `libgnucash/backend/xml/` (`io-gncxml-v2`, `gnc-*-xml-v2`)
  - App utilities — `libgnucash/app-utils/` (`QuickFill`, `gnc-exp-parser`, `gnc-sx-instance-model`, `gnc-autoclear`, `gnc-quotes`)
  - Import/export — `gnucash/import-export/` (`qif-imp`, `ofx`, `csv-imp`, `csv-exp`, generic `import-*matcher`)
  - Reports — `gnucash/report/` (`report-core.scm`, `trep-engine.scm`, `reports/standard/*.scm`)
- FinvestLens [PRD](prd.md), [Architecture](architecture.md), [Implementation Plan](plan.md), [README](../README.md), [LICENSE](../LICENSE).

> FinvestLens is licensed GPLv3 and may incorporate logic derived from GnuCash's GPL source. It is an independent project, not affiliated with or endorsed by the GnuCash project.
