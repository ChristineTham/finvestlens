# Provisioning runbook — App Group, iCloud & extensions

One-time setup so the widgets, Quick Look preview, iCloud sync, and the
app↔extension snapshot hand-off work on a signed build. Everything in the code
is already wired (entitlements, `NSUbiquitousContainers`, extension targets);
what's left is registering the capabilities with your Apple Developer team so
signing is allowed to grant them.

You can do almost all of this **automatically from Xcode** (recommended —
§A). The **portal-only** reference (§B) is there if you use manual signing or
want to pre-create the identifiers by hand.

---

## The identifiers this project expects

These are hard-coded in the entitlements / Info.plists — use them **exactly**,
or change them in both the portal and the files.

| Thing | Value | Where it's declared |
|---|---|---|
| Team ID | `RPL5R637DS` | `DEVELOPMENT_TEAM` in `project.pbxproj` |
| App bundle ID | `com.hellotham.finvestlens` | app target |
| Widget bundle ID | `com.hellotham.finvestlens.FinvestLensWidgets` | widget target |
| Quick Look bundle ID | `com.hellotham.finvestlens.FinvestLensQuickLook` | Quick Look target |
| App Group | `group.com.hellotham.finvestlens.shared` | `finvestlens.entitlements`, `FinvestLensWidgets.entitlements`, `FinvestLensShared.SharedAppGroup` |
| iCloud container | `iCloud.com.hellotham.finvestlens` | `finvestlens.entitlements`, `finvestlens/Info.plist` |

**Capability matrix** (which target needs what):

| Target | App Group | iCloud (Documents) |
|---|---|---|
| `finvestlens` (app) | ✅ | ✅ |
| `FinvestLensWidgets` | ✅ | — |
| `FinvestLensQuickLook` | — | — (just needs its App ID to exist) |

The Quick Look extension reads the previewed file directly, so it needs no App
Group and no iCloud — only a registered App ID so its `.appex` can be signed.

---

## A. The easy path — let Xcode do it (automatic signing)

The project already uses `CODE_SIGN_STYLE = Automatic`. Xcode can create the App
Group, the iCloud container, the three App IDs, and the profiles for you.

1. Open `finvestlens.xcodeproj` in Xcode and sign in with your Apple ID under
   **Settings ▸ Accounts** (the account must belong to team `RPL5R637DS`).
2. Select the **finvestlens** target ▸ **Signing & Capabilities**.
   - Confirm **Automatically manage signing** is on and the Team is
     *RPL5R637DS*.
   - You should already see **App Groups** and **iCloud** listed (they're read
     from the entitlements file). If a capability shows a "register"/"repair"
     button or a red error, click it — Xcode registers the identifier with the
     portal and refreshes the profile.
   - Under **App Groups**, make sure `group.com.hellotham.finvestlens.shared` is
     checked.
   - Under **iCloud**, make sure **iCloud Documents** is ticked and the
     container `iCloud.com.hellotham.finvestlens` is checked. (Leave CloudKit
     unticked — this app uses iCloud *Documents*, not CloudKit.)
3. Select the **FinvestLensWidgets** target ▸ **Signing & Capabilities**.
   - Same Team, automatic signing.
   - Confirm **App Groups** contains `group.com.hellotham.finvestlens.shared` (same
     group as the app — that's how the widget reads the snapshot).
4. Select the **FinvestLensQuickLook** target ▸ **Signing & Capabilities**.
   - Same Team, automatic signing. No capabilities to add; Xcode just needs to
     register its App ID and issue a profile.
5. Let Xcode finish "Preparing"/"Registering". When all three targets show no
   signing errors, you're done — build to a device or a signed macOS build.

If step 2–4 all go green, you can **skip §B entirely** — Xcode has already
created everything in the portal.

---

## B. Portal reference (manual signing, or pre-creating by hand)

Do this at <https://developer.apple.com/account> ▸ **Certificates, Identifiers
& Profiles**. Make sure the account context (top-right team switcher) is team
**RPL5R637DS**.

### B1. Create the App Group

1. **Identifiers** ▸ the **+** button ▸ **App Groups** ▸ Continue.
2. Description: `FinvestLens App Group`. Identifier: `group.com.hellotham.finvestlens.shared`.
3. Register.

### B2. Create the iCloud Container

1. **Identifiers** ▸ **+** ▸ **iCloud Containers** ▸ Continue.
2. Description: `FinvestLens iCloud`. Identifier: `iCloud.com.hellotham.finvestlens`.
3. Register.

### B3. Register the three App IDs (if they don't already exist)

For each bundle ID below: **Identifiers** ▸ **+** ▸ **App IDs** ▸ **App** ▸
Continue, set the Description and **explicit** Bundle ID, then enable the
capabilities noted, and Register.

| Bundle ID | Enable capabilities |
|---|---|
| `com.hellotham.finvestlens` | **App Groups** (assign `group.com.hellotham.finvestlens.shared`) and **iCloud** (select "Include CloudKit support"? **no** — just iCloud; assign container `iCloud.com.hellotham.finvestlens`) |
| `com.hellotham.finvestlens.FinvestLensWidgets` | **App Groups** (assign `group.com.hellotham.finvestlens.shared`) |
| `com.hellotham.finvestlens.FinvestLensQuickLook` | none |

Notes:
- When you enable **App Groups** or **iCloud** on an App ID, you must click
  **Edit/Configure** next to the capability and **tick the specific group /
  container** you created in B1/B2 — otherwise the entitlement is present but
  unassigned and signing still fails.
- iCloud on the App ID is what backs the `CloudDocuments` service +
  `ubiquity-container-identifiers` in the app's entitlements. No CloudKit schema
  is needed.

### B4. Provisioning profiles (manual signing only)

If you turned **off** automatic signing, create a **Development** profile for
each of the three App IDs (**Profiles** ▸ **+** ▸ *iOS/macOS App Development*),
select the matching App ID, your certificate and test devices, download, and
select each in the target's **Signing & Capabilities ▸ Provisioning Profile**.
With automatic signing, skip this — Xcode manages profiles.

---

## C. Verify

1. **Build & sign** (device or a Developer-ID/Development-signed macOS build) —
   signing should now succeed for all three targets. (`CODE_SIGNING_ALLOWED=NO`
   was only for the unsigned CI-style check; real capabilities need real
   signing.)
2. **App Group hand-off** — open a book, make an edit, Save. Then confirm the
   snapshot file exists:
   `~/Library/Group Containers/group.com.hellotham.finvestlens.shared/widget-snapshot.json`
   (macOS). If it's there, widgets will read it.
3. **Widgets** — add the **Net Worth** / **Alerts** widgets from the widget
   gallery; they should show the values from the last-opened book.
4. **Quick Look** — select a `.finvestlens` file in Finder and press **Space**;
   the preview shows the account/transaction/commodity/price counts.
5. **iCloud** — move (or save) a book into **iCloud Drive ▸ FinvestLens**; it
   should sync and reopen across devices signed into the same iCloud account.

---

## If you change the identifiers

If you don't want `com.hellotham.*` / team `RPL5R637DS`, update **all** of:
`DEVELOPMENT_TEAM` and the three `PRODUCT_BUNDLE_IDENTIFIER`s in
`project.pbxproj`; the group id in the two `.entitlements` files **and**
`Packages/Shared/Sources/FinvestLensShared/SharedAppGroup.swift`; the iCloud
ids in `finvestlens.entitlements` and the `NSUbiquitousContainers` key in
`finvestlens/Info.plist`. Then register the new identifiers per §B.
