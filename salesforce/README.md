# HCP Consent Capture – Salesforce implementation

This is the Salesforce build of the approved clickable mockup (`../index.html`, 7 steps).
It is an SFDX project that **you deploy yourself** to the Agentforce Developer Edition org
(alias `dev-consent`). Phases 1–2 are deployed (57/57 tests passing). The phase 4 work (hospitals and
departments, matching v2, volume test data, Matching & Duplicates workbench) and the Prompt Builder class
are **not deployed yet**. See [Known limitations / not verified](#6-known-limitations--not-verified).

## 1. Phased plan

| Phase | Scope | Status in this repo |
|---|---|---|
| **1** | Data model, async matching, review console, consent record and Gigya status, dashboard and reports, permission sets, sample data | **Code complete**, not yet deployed |
| **2** | Experience Cloud: public QR page, kiosk mode, double opt-in confirmation page, rep page (search first, signature, dictation, rule-based extraction) | **LWCs and Apex complete**. You create the sites in the UI (section 4) |
| **3** | AI with Prompt Builder: "Extract with AI" on notes, review recommendation | "Extract with AI" **code complete** (`force-app-ai`, section 8), needs the Prompt Builder setup; rules stay as fallback. Review recommendation: design only |
| **4** | Hospitals & departments, matching v2 (parametric), volume test data with accuracy measurement, Matching & Duplicates workbench with HCP merge | **Code complete**, not yet deployed (sections 9–12) |

### Defaults I chose (change them if you disagree)

- **Objects**: custom objects only (`Capture__c`, `Capture_Candidate__c`, `Consent__c`, `Event__c`, `Event_Attendee__c`, `HCP_Affiliation__c`, `HCP_Duplicate_Pair__c`, `HCP_Merge__c`), so internal users can be on the **Salesforce Platform** license. HCPs are standard `Contact` records with custom fields. Hospitals and departments are `Account` records (record types `Hospital` / `Department`); `Contact.AccountId` = the HCP's primary department (section 9).
- **Async matching**: a `Capture__c` insert publishes the platform event `Capture_Matching_Request__e`. Its subscriber runs as the *Automated Process* user. Guest and rep transactions therefore never create HCPs or consents themselves.
- **Guest security**: the guest user gets **Apex class access only** (no object permissions). `PublicCaptureController` is `without sharing` with strict server-side validation, a honeypot field, an HMAC-signed form token (minimum fill time 3 s, maximum age 4 h) and rate limits (3 per email per event per day, 30 per event per minute). It never returns record Ids. Guest-created captures are re-owned by the **event owner** during matching.
- **Kiosk hardening**: in kiosk mode the form fields use `autocomplete="off"` (no suggestions of the previous visitor's name or email on the shared tablet), the on-screen keyboard is closed on reset, and the form empties after each submit. The per-email limit (3/day) is the same as the QR page; there is no per-device limit (demo).
- **Kiosk signature** (pending Legal, open question L2): at the kiosk the HCP chooses **Confirm by email** (double opt-in, default) or **Sign here on the tablet**. Signing gives the same evidence as the rep flow (PNG file on the capture, SHA-256 in `Signature_Hash__c`, consent *Opt-in confirmed* with method *Explicit question + signature*, copy emailed to the HCP with the slides link), but **no rep witnesses it**: `Captured_By__c` is empty and `Capture_Device__c` starts with `Kiosk |`. The server accepts a signature only in kiosk mode and only as a PNG (max ~1.5 MB). If the file cannot be stored, nothing is saved and the HCP is asked to use email.
- **Double opt-in token**: 256-bit random token in the link. Only its SHA-256 hash is stored (`Confirmation_Token_Hash__c`), and it is valid for 30 days. The confirmation page asks the HCP to **press "Confirm"** rather than confirming on page load, because corporate email scanners pre-open links (see open question L4).
- **Territory**: `User.Territory__c` and `Contact.Territory__c` (text). The rep search returns **every HCP in Salesforce** the rep can see. HCPs of the rep's own territory are listed first; the others carry an "Other territory" badge. Visibility follows the org sharing model, so Contact/Account sharing must not be Private for reps (it is Public in a fresh Developer Edition).
- **Path** on the capture page is drawn inside the `captureReview` LWC (Received → Auto-matching → To review → Matched → Consent created → Sent to Gigya). This avoids Path settings metadata.
- **Dashboard**: an LWC dashboard with the mockup's event filter (tab *Capture Dashboard*). Standard reports and a standard dashboard are also provided in `force-app-extras`.
- **Consent text** v3.2 lives in Custom Metadata (`Consent_Text__mdt`). The active record with the highest version is shown everywhere and its text is snapshotted on each consent record.
- **Rep names in the sample data** (Anna Colombo, Davide Ricci, Sara Fontana) are stored as text (`Captured_By_Name__c`) because a Developer Edition has too few licenses to create three real rep users. Real captures also set the `Captured_By__c` user lookup.

## 2. What is in the project

```
salesforce/
├── sfdx-project.json            # two package dirs: force-app (core) + force-app-extras
├── force-app/main/default/
│   ├── objects/                 # Capture__c, Capture_Candidate__c, Consent__c, Event__c, Event_Attendee__c,
│   │                            # Contact + User fields, Consent_Capture_Settings__c (hierarchy setting),
│   │                            # Consent_Text__mdt, Capture_Matching_Request__e (platform event), list views
│   ├── classes/                 # Apex (+ tests)
│   ├── triggers/                # CaptureTrigger, CaptureMatchingRequestTrigger
│   ├── lwc/                     # hcpPublicCapture, repCaptureHub, signaturePad, captureReview,
│   │                            # consentTimeline, captureDashboard
│   ├── flexipages/              # Capture/Consent record pages, Rep Capture Hub + Capture Dashboard app pages
│   ├── applications/            # Lightning app "HCP Consent Hub"
│   ├── permissionsets/          # HCP_Consent_Admin / _Rep / _Data_Steward / _Guest
│   ├── customPermissions/, customMetadata/, globalValueSets/, layouts/, tabs/
├── force-app-extras/main/default/
│   ├── reports/, dashboards/    # 7 reports + "Capture performance" dashboard
│   └── layouts/                 # Contact Layout + Account Layout: REPLACE the default layouts (fine on a fresh org)
├── force-app-ai/main/default/   # NotesExtractionAI (Prompt Builder call), deployed after the Einstein setup
└── scripts/apex/                # configure, territory, sample data, Gigya simulation, reset, event URLs
```

| Apex class | Role |
|---|---|
| `PublicCaptureController` | Guest: form context, submit, double opt-in confirmation |
| `ConsentService` | Tokens, confirmation email, confirm, Contact consent summary, signature file |
| `CaptureMatchingService` | Matching rules, candidate scoring, deterministic suggestion text |
| `CaptureResolutionService` | New HCP creation, consent record creation or reuse, attendee, task/signature linking |
| `RepCaptureController` | Rep page: events, HCP search (own territory first), add known HCP, walk-in, my captures |
| `NotesExtractionService` | Phase 1 rule-based "Extract with AI" (phase 3 swaps in Prompt Builder) |
| `CaptureReviewController` | Steward actions: Match / Create new HCP / Discard / re-run matching |
| `ConsentRecordController` | Gigya timeline, simulate sync (demo), withdraw consent |
| `CaptureDashboardController` | Dashboard figures with event filter |
| `ConsentDemoData` | Settings, sample data (mockup HCPs now in hospitals / departments), reset |
| `MatchingConfig` | Matching parameters from Custom Metadata `Matching_Setting__mdt` (record `Default`) |
| `HcpMatchEngine` | Deterministic comparison of two HCP profiles: name (identical / swapped / typo / surname), email and domain, registration number, hospital / department, specialty, city; flags and score explanation |
| `HcoDirectory` | Hospitals and departments cache; resolves a hospital from free text (name, aliases) or email domain |
| `AffiliationService` + `HcpAffiliationTrigger` | One primary affiliation per HCP; `Contact.AccountId` = primary HCO; unique affiliation key |
| `VolumeTestData` | Test only. Batch: ~30 hospitals, ~1,000 HCPs with hard cases, 150 test captures with expected outcomes; cleanup |
| `MatchingAccuracyController` | Accuracy KPIs on the test captures; starts the generator |
| `DuplicateScanJob` | Batch: proposes duplicate HCP pairs with the matching engine |
| `HcpMergeService` | HCP merge (`Database.merge`) with audit record; evidence lookup after merges |
| `MatchingWorkbenchController` | Matching & Duplicates workbench: queue, pairs, comparison, merge, "not a duplicate" |
| `NotesExtractor` / `NotesExtractionAI` | Pluggable "Extract with AI": Prompt Builder (force-app-ai) with rule-based fallback |

### Matching rules (mockup step 4) – v2

The rule order and the safety principle are unchanged: **only identical identifiers auto-match; anything
ambiguous goes to a person**. All weights and thresholds are parameters (section 10).

0. Rep picked the HCP from search → **Auto-matched** ("HCP selected by rep")
1. Identical email (case-insensitive), **exactly one HCP**, no conflicting registration number → **Auto-matched**
2. Identical registration number (normalised: upper case, letters and digits only, leading zeros removed, so `mi 020418` = `MI-20418` = `MI/20418`), **exactly one HCP** → **Auto-matched**
3. Any candidate → **To review**: up to 10 ranked candidates in `Capture_Candidate__c` with per-field flags (Exact / Partial / None / Not captured) and a **score explanation**, one line per rule (e.g. `+30 full name identical`, `+10 same hospital (Gaslini Institute)`, `-20 registration numbers differ`). A candidate is an HCP with
   - the same full name (accent-insensitive: Nicolò = Nicolo, D'Amico = Damico), first and last name **swapped**, a **similar name** (Levenshtein distance ≤ 1 under 7 letters, ≤ 2 from 7 letters; two swapped letters count as one typo; an initial matches the first name), or the same surname (namesakes);
   - or an identical email / registration number that could not auto-match because it is **shared by several HCPs** (likely duplicates) or **contradicted** (email → HCP A but registration number → HCP B, or the same HCP with a different registration number). The suggestion then starts with "Attention: …".
4. No candidate → **New HCP**: the Contact is created under the department (captured, or the department of the captured hospital that fits the specialty) or the hospital, with a primary affiliation. When no hospital is known it goes under "HCPs - organisation unknown" (no Hospital Account is created from free text).

Candidates are fetched by email, registration number, the first 3 letters of surname **and** first name (so swapped names meet) and **every HCP affiliated with the capture's hospital**. The capture's hospital is the one the rep picked, otherwise it is resolved from the organisation text (hospital name or `Aliases__c`, accent-insensitive; ambiguous text resolves to nothing) or from an institutional email domain (`Account.Email_Domain__c`; personal domains such as gmail.com never count).

Default points (score capped at 0–100): full name 30 · swapped 25 · similar name 20 · surname only 15 · email 20 · same institutional domain 5 · registration number 15 (−20 when both exist and differ) · same department 15 · same hospital 10 · organisation text similar 5 · specialty 10 · city 10. Candidates under 15 points are dropped. Confidence **High** from 60 points with a lead of 10 over the second candidate, otherwise Medium (Low under 30).

After an HCP is known:
- consent **reused**: the capture is linked to the latest confirmed consent and no new record is created;
- consent **declined**: no consent record; the HCP becomes an attendee with `Communications_Allowed__c = false`;
- otherwise a `Consent__c` is created: *Opt-in confirmed* (signature, or email already confirmed) or *Pending double opt-in*.

In every case the HCP is added as an `Event_Attendee__c`, a follow-up Task is linked to the Contact, and `Contact.Consent_Status__c` is recalculated.

Gigya: a confirmed consent has `Gigya_Status__c = Queued`. The **existing integration** is expected to pick it up and set *Sent*. For the demo, use **Simulate sync** on the consent page or script `04`.

## 3. Deploy (exact commands)

Prerequisites: [Salesforce CLI](https://developer.salesforce.com/tools/salesforcecli) (`sf --version` ≥ 2.x).

```bash
cd salesforce

# 0. Log in (browser opens; you type the credentials yourself)
sf org login web --alias dev-consent --instance-url https://login.salesforce.com --set-default

# 1. Core metadata + Apex. Developer Edition is a production-type org: local Apex tests run automatically.
sf project deploy start --source-dir force-app --target-org dev-consent --test-level RunLocalTests --wait 30

# 2. Reports, dashboard and the Contact / Account layouts (separate, so a problem here never blocks the core)
sf project deploy start --source-dir force-app-extras --target-org dev-consent --wait 30

# 2-bis. Optional, after the Prompt Builder setup (section 8): the "Extract with AI" class
sf project deploy start --source-dir force-app-ai --target-org dev-consent --test-level RunLocalTests --wait 30

# 3. Permission sets for yourself (admin = everything, both custom permissions)
sf org assign permset --name HCP_Consent_Admin --target-org dev-consent

# 4. Settings, your territory, sample data (run them one by one, in this order)
sf apex run --file scripts/apex/01-configure.apex   --target-org dev-consent
sf apex run --file scripts/apex/02-my-territory.apex --target-org dev-consent
sf apex run --file scripts/apex/03-sample-data.apex  --target-org dev-consent
#    wait ~10 seconds for async matching, then optionally:
sf apex run --file scripts/apex/04-simulate-gigya.apex --target-org dev-consent
#    volume test data (~2 minutes, Batch Apex), then the duplicate scan:
sf apex run --file scripts/apex/05-volume-data.apex --target-org dev-consent
sf apex run --file scripts/apex/06-duplicate-scan.apex --target-org dev-consent

# 5. Open the app
sf org open --target-org dev-consent --path lightning/app/c__HCP_Consent_Hub
```

If step 1 fails, paste me the full error output (component name and message) and I will fix it.
To see test results with coverage: `sf apex run test --test-level RunLocalTests --code-coverage --result-format human --target-org dev-consent --wait 20`.

Re-run `01-configure.apex` after creating the public site, with its real URL. Use `scripts/apex/event-ids.apex` to print the QR and kiosk URLs for each event.
To start over: `sf apex run --file scripts/apex/99-reset-sample-data.apex --target-org dev-consent`, then run `03` again.
**Org already loaded before phase 4**: the mockup HCPs were created without hospitals and departments. Run `99-reset-sample-data.apex` and then `03-sample-data.apex` once after the phase 4 deploy (the reset never touches volume test data).
Volume data: `07-regenerate-test-captures.apex` re-creates only the 150 test captures (after changing matching parameters); `98-cleanup-volume-data.apex` deletes all of it.

## 4. Manual setup in the UI (cannot be deployed reliably as metadata)

### 4.1 Email (needed for double opt-in)
1. Setup → **Deliverability** → Access level = **All email**. In some new orgs it is "System email only", and then every confirmation email shows `Confirmation_Email_Status__c = Failed`.
2. Optional: Setup → **Organization-Wide Addresses** → add and verify e.g. `no-reply@…`. Put the address in Setup → Custom Settings → *Consent Capture Settings* → Manage → *Org-Wide Email Address*.

### 4.2 Public site (QR self-scan, kiosk, confirmation page)
1. Setup → **Digital Experiences → Settings** → enable Digital Experiences and choose a domain → Save.
2. **All Sites → New → Build Your Own (LWR)**. Name `HCP Consent`, URL suffix **`hcp`**.
3. In Experience Builder:
   - Home page → drag the custom component **HCP Public Capture** onto the page. Leave *Default event Id* empty, so the URL `?e=` is used.
   - Settings → General → **Guest user profile** link → note the guest user.
   - Settings → **Security & Privacy**: keep "Public can access the site" **on**, and the "Guest user record access" defaults on (secure guest access).
   - **Publish**.
4. Setup → Users → the site guest user (name like *HCP Consent Site Guest User*) → **Permission Set Assignments** → add **HCP Consent - Public Site Guest** (`HCP_Consent_Guest`). Do not give the guest profile any object permissions.
4b. Kiosk signature: Setup → **Salesforce Files → General Settings** → tick **Allow site guest users to upload files** → Save. Without it the kiosk "Sign here on the tablet" option answers "could not save your signature" (email confirmation keeps working).
5. Setup → Digital Experiences → All Sites → *HCP Consent* → **Workspaces → Administration → Preferences**: set the **default owner for records created by guest users** to an internal user (required by Salesforce; matching then moves the capture to the event owner).
6. Copy the site URL (e.g. `https://<domain>.my.site.com/hcp`), put it in `scripts/apex/01-configure.apex` and run that script again.
7. **QR codes for posters**: open any event (tab *HCP Events*). The record page shows the **booth QR** (self-scan) and the **kiosk QR**, with **Download PNG** (1200 px) / **Download SVG** (vector, best for print) / **Copy link**. Admins and data stewards only.
   URLs behind the codes:
   - QR at the booth: `https://…/hcp?e=<EventId>&ch=qr`
   - Kiosk tablet: `https://…/hcp?e=<EventId>&mode=kiosk`
   - Confirmation link in the email: `https://…/hcp?t=<token>` (generated automatically)

### 4.2-bis Try the HCP page without a site (Lightning preview)
The tab **HCP Public Page (preview)** in the *HCP Consent Hub* app shows the same public component inside Lightning, logged in as you. Open it with an event:
`/lightning/n/HCP_Public_Preview?c__e=<EventId>` (add `&c__mode=kiosk` for kiosk). `scripts/apex/event-ids.apex` prints these URLs.
To test the confirmation email before the site exists, run `01-configure.apex` with the preview URL (`https://<your-domain>.lightning.force.com/lightning/n/HCP_Public_Preview`): the link then uses `c__t=`. The preview is for demos only: the guest-user security is tested only on the real site.

### 4.3 Rep page (Experience Cloud for internal users)
1. Create a second site, **Build Your Own (LWR)**, name `HCP Rep`, URL suffix **`rep`**.
2. Experience Builder → Home → drag **Rep Capture Hub**. Settings → Security & Privacy → **turn off** public access (login required). Publish.
3. Workspaces → Administration → **Members** → add the permission set **HCP Consent - Rep** (and/or the profile *Standard Platform User*). Activate the site.
4. Reps log in at `https://<domain>.my.site.com/rep` with their normal Salesforce username.
5. Shortcut for testing: the same component is the **Rep Capture Hub** tab in the *HCP Consent Hub* app.

### 4.4 Users
- **Rep**: license *Salesforce Platform*, profile *Standard Platform User*, permission set **HCP Consent - Rep**, field **Territory** = `IT-PED-01` for the demo. It only orders search results: the sample HCPs in `IT-PED-01` (Ferri, Romano, Conti, Gallo, Rinaldi, Villa, Greco, Sala, Benedetti) come first, and the others are shown with an "Other territory" badge.
- **Data steward**: license *Salesforce Platform*, profile *Standard Platform User*, permission set **HCP Consent - Data Steward** (now also: Matching & Duplicates tab, affiliations, duplicate pairs, merge history, Contact delete for merges, Account record types Hospital / Department).
- **Admin / demo**: you, with **HCP Consent - Admin**.
- Reports and dashboard folders are private to you after deploy. Share *HCP Consent Reports* and *HCP Consent Dashboards* with stewards and marketing from the Reports tab (folder → Share).

## 5. Test checklist (per mockup step)

**Step 1 – Self-scan (public page)**
- [ ] Open `…/hcp?e=<CongressId>&ch=qr` in a private window. The header shows the congress name and the form shows 5 required fields plus the optional registration number.
- [ ] Submit with fields missing: they are highlighted and nothing is created.
- [ ] Submit valid data (use an email you can read). A thank-you page appears, and the *Captures* tab shows a new capture with Channel = Self-scan and Opt-in = Pending.
- [ ] The email arrives. The link opens the confirmation page; after **Confirm** you see "Consent confirmed" and a slides download button. The capture shows Opt-in = Confirmed and its consent shows Opt-in confirmed with Gigya status Queued.
- [ ] Reopen the link: it still shows "confirmed". Change one character of the token: you get "not valid".
- [ ] Submit the same email 4 times: the 4th is refused (rate limit).

**Step 2 – Rep page**
- [ ] Select the congress, then search `Ferri`: card shows "Consent on file", **Add to event** adds without question.
- [ ] Search `Sala`: consent only *pending* (the congress capture was never confirmed), so the card shows the question → *signs on screen* → draw → **Confirm signature & add** → capture with signature file; after matching a consent *Opt-in confirmed* with Signature captured. (In the mockup this case was Greco; in the sample data Greco's congress capture is already confirmed, so Greco now shows "Consent on file".)
- [ ] Search `Conti`: "Opted out" → only *signs on screen* and *declines* are offered.
- [ ] Search `Bianchi` → the 3 Bianchi namesakes appear with an "Other territory" badge (found anyway). Search `Rossi` → "No HCP found" → **Add as walk-in**. Alternatively, with results on screen, use **Not in the list? + Add as walk-in** → paste/dictate the demo note → **Extract with AI** fills 7 fields + task "Call back Dr. Maria Bianchi" due Mon 2 Nov 2026 → choose a consent option → **Save capture** → *My captures today* lists it with "Follow-up task".
- [ ] Microphone: on Chrome/Android it dictates. Where the browser has no Web Speech API, a hint asks you to use the keyboard microphone.

**Step 3 – Kiosk**
- [ ] `…/hcp?e=<TrainingId>&mode=kiosk` shows the large two-column layout. After submit the page counts down 6 s and resets. The capture's Channel is Kiosk.
- [ ] Type a name and email, submit, then start typing the same name for the next visitor: the browser offers no suggestion (if it still does, see the kiosk note in section 6).
- [ ] Choose **Sign here on the tablet** → submitting without drawing highlights the box → draw → **Register** → "Your consent is recorded. A copy has been sent to your email." The capture has Consent method *Explicit question + signature*, Opt-in Confirmed, a signature file and `Capture_Device__c` = `Kiosk | …`; after matching its consent is *Opt-in confirmed* with Signature captured and the file is linked to it.

**Step 4 – Automatic matching** (after `03-sample-data.apex`)
- [ ] *Captures* → list view **All captures**: 8 Auto-matched (email: Villa, Ferri, Conti, Gallo, Greco; registration number: Romano, Rinaldi, Sala), 2 To review (Maria Bianchi, Roberto Esposito) and 2 New HCP (Leone, Marchetti).

**Step 5 – Review console**
- [ ] List view **To review** shows 2 captures. Open Maria Bianchi: path at "To review"; suggestion "Recommended: Dr. Maria Bianchi - same surname, city and specialty", confidence High; 3 candidates side by side with green/amber cells.
- [ ] **Match** → path moves to Consent created and a consent is linked. Esposito → **Create new HCP** or **Discard** both work, and buttons disappear once resolved.

**Step 6 – Consent record**
- [ ] Open a consent → details (type, channel, method, version, captured by, matched by, source capture, event) plus the Gigya timeline. **Simulate sync (demo)** → "Sent to Gigya ✓" and the capture stage becomes *Sent to Gigya*.
- [ ] HCPs with consent on file (Ferri, Romano, Benedetti) get **no** new consent when reused from the rep page.

**Phase 4 – Hospitals, matching v2, workbench** (after `99` + `03`, then `05` and `06`)
- [ ] Accounts → *Gaslini Institute*: record type Hospital, related list *HCP Affiliations*. Dr. Maria Bianchi (Genoa): Account = *Paediatrics - Gaslini Institute*, related list *Affiliations*.
- [ ] Mockup capture of Maria Bianchi: Hospital = Gaslini Institute (resolved from "Gaslini"), confidence High; the comparison table has the rows *Hospital / department* and *Why this score*.
- [ ] Rep page: search `Rinaldi` → the card shows hospital, department and "Also works in". Walk-in: type `gasl` in Hospital → pick *Gaslini Institute* → the Department list appears; save → the capture has Hospital and Department.
- [ ] Tab **Matching & Duplicates** › *Review queue*: tick 2 captures → **Match to recommended** → Confirm → they leave the queue. Click a capture name → the side-by-side review opens below.
- [ ] *Accuracy*: 150 test captures, auto-match precision, review rate, false new-HCP rate, table by test case, duplicate recall. Change a weight in Setup › Custom Metadata Types › Matching Setting › Default, click **Regenerate test captures only**, wait about a minute, **Refresh**: the figures change.
- [ ] *Duplicate HCPs*: pairs with score ≥ 50, filters hospital / department. Open a pair → choose the survivor and per-field values → **Merge…** → **Confirm**. *Merge history* shows who, when and the moved records. Open a consent of the merged HCP → **Verify evidence** says "intact … merged into this HCP on …".
- [ ] Mark another pair **Not a duplicate** → run the scan again → the pair stays under *Not a duplicate*.
- [ ] Dictation on Chrome (desktop or Android): tap 🎤, speak, pause a few seconds: dictation continues and shows the interim text; the IT/EN chip switches language. Block the microphone in the site settings → a message explains how to allow it or use the keyboard microphone.

**Step 7 – Dashboard**
- [ ] Tab **Capture Dashboard**: KPIs, channel bars, captures per rep, matching and consent donuts. The event filter changes the figures.
- [ ] Reports tab → *HCP Consent Reports* (6 reports). Dashboards tab → *Capture performance*.

## 6. Known limitations / not verified

**Not verified (phase 4 and Prompt Builder).** I have no org access and no Salesforce compiler: phases 1–2 were verified by your deploy (57/57 tests); everything added in phase 4 is checked only locally:
- every Apex file parses (prettier-plugin-apex / jorje parser);
- every LWC compiles with `@lwc/compiler`;
- `sf project convert source` succeeds on the package directories;
- all XML is well-formed;
- a script cross-checks that every field, object, class, tab and LWC referenced by Apex, LWC, layouts, list views, permission sets and flexipages exists in the project.

Semantic Apex errors (types, SOQL against the real schema) and test outcomes are **only verified when you deploy**. Most likely phase 4 deploy issues, which I will fix from the error output:
- Account record types (Department record type picklist values) and Apex inserting Accounts with these record types in tests (tests run as a user with the admin permission set, which grants them);
- `PlatformEventSubscriberConfig` (batch size 50 for the matching trigger), a metadata type not used before in this project;
- `Database.merge` on Contacts and the reparenting of master-detail affiliations during a merge;
- CPU time of the matching transaction with ~1,000 HCPs (expected well within limits, not measured);
- the Account layout in `force-app-extras` **replaces** "Account Layout", like the Contact layout. Fine on a fresh org; skip those files otherwise;
- `force-app-ai`: the `ConnectApi` Prompt Builder types (only compiled by Salesforce, never locally).

Functional and platform limits:
- **Email limits**: Apex single emails to external addresses are limited per org per day. On Developer Edition the limit is very small (single digits to ~15/day). In production it is typically 5,000/day. When the limit is reached the capture is still saved with `Confirmation_Email_Status__c = Failed`; there is no automatic resend in phase 1. Use Marketing Cloud or a transactional email service for high volume (open question T2).
- **Bot protection** is honeypot + signed token + rate limits. There is **no CAPTCHA** (reCAPTCHA in LWR needs extra setup; open question T1).
- **Candidate retrieval** uses the first 3 letters of surname and first name, the email, the registration number and the capture's hospital. A typo in the **first 3 letters** of the surname of an HCP from another hospital is not found (it becomes a New HCP, which the duplicate scan then proposes only if surname or first name start with the same letter). Accent-insensitivity is applied in Apex, after retrieval.
- **Duplicate scan** blocks by initial letter of surname / first name, plus identical email or registration number; HCPs whose names start with different letters and share nothing else are not compared. Fine for ~10,000 HCPs; beyond that, run it per territory or move the blocking keys into an indexed field.
- **Merge** runs in Apex (`without sharing`, steward custom permission checked). Data stewards get Contact *Delete* in their permission set because merging deletes the duplicate. Not verified with a real Salesforce Platform license user (tests use admin-profile users).
- **Record types**: the admin and steward permission sets grant Hospital / Department. If your profile has record type restrictions, also make them available on the profile.
- Two captures of the **same new HCP in the same batch** create two Contacts (rare; the duplicate scan proposes them and the steward merges them).
- **Territory** is a plain text field used only to order the rep search (own territory first); it does not restrict visibility.
- **Gigya**: only a status field and timeline. "Simulate sync" is a demo stand-in for the real integration.
- **Dictation** uses the browser Web Speech API (Chrome / Edge / Android / Safari) with auto-restart after pauses, interim text, an IT/EN language switch and explicit microphone-permission messages. Firefox and some in-app browsers have no Web Speech API: the page then asks to use the keyboard microphone. Not verified inside the Salesforce mobile app (its WebView may not expose the API) nor in every LWR + Lightning Web Security combination; the keyboard fallback always works.
- **Matching transactions**: the platform-event subscriber processes at most 50 captures per transaction (`PlatformEventSubscriberConfig`), to stay within limits at congress peaks and for the 150 test captures.
- The **slides** are a URL on the event (`Slides_Url__c`), shown after confirmation; no file is emailed.
- **Kiosk**: the device must stay on the page. Use the browser or OS kiosk / guided-access mode. Browsers may ignore `autocomplete="off"` for saved address profiles: on the kiosk tablet also turn off autofill (Chrome: Settings › Autofill › Addresses and Payment methods off; iPad Safari: Settings › Safari › AutoFill off) or use a guest / private profile, so no visitor data stays on the device.
- **Kiosk signature** is stored by the guest user: the file's owner is the site guest user and it is shared through the capture (and the consent after matching). Its owner cannot be changed afterwards.
- Capture records keep the HCP data entered at capture time; they are not deleted after matching (retention period: open question L5).

## 7. Open questions (not decided here)

For Legal / DPO:
- **L1** Is the double opt-in email (no signature) sufficient for the self-scan and kiosk channels in every country concerned? (Compliance approved it for the email flow; please confirm the scope.)
- **L2** On-screen signature as evidence for explicit consent and for re-collecting after an opt-out: is a PNG stored as a Salesforce file, without signer authentication, enough? Is a retention period needed for signatures? **Kiosk**: the HCP also signs on the unattended kiosk tablet, with no rep as witness (only the device and time are recorded). Is that acceptable, or must the kiosk keep email double opt-in only? (Built for the demo; removing it means hiding the option in `hcpPublicCapture`.)
- **L3** Declined HCPs are stored as attendees with "no communications". Is this the right legal basis (legitimate interest / event attendance records)?
- **L4** The confirmation page asks for an explicit click instead of confirming on link open. Please confirm this is acceptable.
- **L5** Retention and deletion of capture (staging) records, including discarded ones, and of rep notes. Is a privacy notice link required on the public form? (The consent text references the Privacy Notice; the URL must be provided.)
- **L6** Consent text versioning: when v3.3 is published, should HCPs with v3.1/v3.2 be asked again?

For IT:
- **T1** CAPTCHA on the public page (Google reCAPTCHA via LWR, or Salesforce bot protection add-ons)?
- **T2** Email volume at congresses vs. Salesforce daily email limits. Should the confirmation email move to Marketing Cloud?
- **T3** Does the existing Gigya connector read `Consent__c` as-is, or do the field names need mapping to the Pitcher object?

## 8. Phase 3 – "Extract with AI" with Prompt Builder

How it works: `RepCaptureController.extractFromNotes` → `NotesExtractionService.extractSmart`. When *Consent Capture Settings › Use Prompt Builder* is on, it loads the class `NotesExtractionAI` (package directory `force-app-ai`) with `Type.forName` and calls the flex template; the JSON answer is validated (picklist specialty, email format, future due date) into the same `Result`. On any problem (class not deployed, template missing, Einstein error, empty answer) the rule-based extraction answers, and `Result.source` says which one was used (shown in small print on the rep page). The core never depends on Einstein, so it deploys and its tests run without it.

**Setup steps (you, in the org):**
1. Setup › **Einstein Setup** → turn on **Einstein** (Agentforce Developer Edition: usually already on). Setup › **Einstein Generative AI** → accept the terms if asked.
2. Assign yourself (and reps) the permission set **Prompt Template User** (Setup › Users › Permission Set Assignments). To create the template you need **Prompt Template Manager**.
3. Setup › **Prompt Builder** → **New Prompt Template**:
   - Type **Flex**, Name `HCP Notes Extraction`, API name **`HCP_Notes_Extraction`**.
   - Inputs: `notes` (Free Text) and `today` (Free Text).
   - Model: the default (or any available model).
   - Template text:
     ```
     You extract data about a healthcare professional from a sales rep's note (English or Italian).
     Today is {!$Input:today}. Note: "{!$Input:notes}"
     Answer ONLY with one JSON object, no other text, with these keys (use null when unknown):
     firstName, lastName, email, specialty, city, organisation, interest, taskTitle, taskDueDate.
     specialty must be one of: Paediatrics, Neonatology, Paediatric Gastroenterology, Paediatric Allergy,
     Dietetics & Nutrition, General Practice, Gynaecology. city in English (Genova -> Genoa, Milano -> Milan).
     organisation = the hospital as written. taskDueDate = yyyy-MM-dd in the future (e.g. "call back in
     November" -> the first Monday of next November); taskTitle like "Call back Dr. <first> <last>".
     Do not invent data that is not in the note.
     ```
   - **Preview** with the demo note, check the JSON, **Save** and **Activate**.
4. Deploy the class: `sf project deploy start --source-dir force-app-ai --target-org dev-consent --test-level RunLocalTests --wait 30`
5. Setup › Custom Settings › **Consent Capture Settings** › Manage › Edit: tick **Use Prompt Builder** (leave *Prompt Template* empty for `HCP_Notes_Extraction`).
6. Rep page → walk-in → paste the demo note → **Extract with AI**: the result line shows *(Prompt Builder)*. If it shows *(Rules (Prompt Builder unavailable: …))*, the reason follows.

Not verified: the `ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate` call (input names `Input:notes` / `Input:today`, application name `PromptBuilderPreview`) and the model answer format were written from the documentation, not run. Einstein requests consume the org's generative AI allowance. The review recommendation with a Record template remains design only: rules stay authoritative, AI only suggests.

## 9. Hospitals and departments (HCOs)

- `Account` record types **Hospital** and **Department**. A department's `ParentId` is its hospital and `Department_Type__c` its type (Paediatrics, Neonatology, Neonatal Intensive Care, Paediatric Gastroenterology, …). Hospitals carry `Email_Domain__c` (institutional domains, comma separated), `Aliases__c` (other names, semicolon separated) and `OneKey_Workplace_Id__c`.
- **`HCP_Affiliation__c`** (junction): HCP (master-detail to Contact) · Department / Hospital (`HCO__c`) · Role · Primary · Start / End date · formulas Active, Hospital, Department · unique `Affiliation_Key__c` (no duplicate affiliation).
- The trigger keeps **exactly one primary affiliation per HCP** (the one just marked primary wins; when the primary is deleted or ended, the most recent active one is promoted) and sets **`Contact.AccountId` = the primary HCO**.
- Why a custom junction and not `AccountContactRelation`: ACR needs "Contacts to Multiple Accounts" switched on by hand before any deploy that references it, forces the direct relation to equal `AccountId`, and gives less control over keys, validation and merge behaviour. The custom object deploys as metadata, works with the Platform license, is reparented automatically by `Database.merge`, and can be replaced by ACR later if standard ACR reporting becomes a requirement.
- Permission sets: Account record types visible for admin and steward; affiliations read-only for reps, editable for stewards.

## 10. Matching parameters (Custom Metadata)

Setup › Custom Metadata Types › **Matching Setting** › Manage Records › **Default** › Edit. Changes apply to the next capture matched (no deploy). Fields: the weights listed in section 2, *Penalty: registration numbers differ*, *Max edit distance* (short / long names) and *Long name length*, *Minimum candidate score*, *High confidence score* and *gap*, *Maximum candidates per capture*, *Duplicate pair minimum score*, *Auto-match on identical email*, *Auto-match on identical reg. number*, *Review on conflicting evidence*, *Personal email domains*. An empty field falls back to the built-in default. A Custom Metadata Type was chosen over a Custom Setting because it deploys with the code, is versioned in git, is visible in Apex tests without DML and can still be changed in Setup.

## 11. Volume test data and accuracy

`VolumeTestData` (Batch Apex, one step per transaction, fixed random seed, so every run creates the same data):
- 30 Italian hospitals (fictitious `-example.it` domains; two share the name "Ospedale Santa Maria della Misericordia", in Udine and Perugia), each with 3–8 departments; ~1,000 HCPs with Italian names (some with accents or apostrophes), the specialty of their department, city, registration number (85%), OneKey ID, institutional (65%) / personal (20%) / no email, ~10% in 2 departments.
- Hard cases: 25 namesakes in other cities and 30 **real duplicates** (same email with the accent dropped; personal email and registration number typed differently; swapped names; surname typo; moved to another hospital), marked with `Contact.Test_Duplicate_Of__c`.
- 150 test captures (event "Matching accuracy test set (synthetic)", inactive) in 14 test cases with `Expected_Outcome__c` / `Expected_Contact__c` / `Test_Case__c`: exact email, registration number in another format, personal email + hospital, surname typo, accent variant, swapped names, namesake, really new HCP, new HCP with an existing surname, email of a duplicate record, email shared by duplicates, new address at the same institution, email/registration conflict, typo without hospital.
- The mockup surnames are not used, so the mockup demo keeps its outcomes; mockup HCPs and events are never touched. Every generated record carries `Test_Data_Set__c` (`VOLUME`, `VOLUME-CAPTURES`) and is removed by the cleanup.

**Accuracy** (Matching & Duplicates › Accuracy, and the report *Matching accuracy - test captures*): auto-match precision (auto-matched to the right HCP or to a known duplicate record of it), review rate, false new-HCP rate (a new Contact created for an HCP that exists), right HCP among the review candidates and as the recommendation, outcome as expected per test case, the captures to look at, and duplicate-scan recall / precision on the known duplicates. **Not run yet**: the figures will be known after your deploy.

## 12. Matching & Duplicates workbench (data stewards)

Tab **Matching & Duplicates** (app page with the `matchingWorkbench` LWC):
- **Review queue**: captures *To review* with hospital, recommended HCP, score and confidence; filters hospital / confidence; bulk **Match to recommended / Create new HCPs / Discard** (max 50, with confirmation); click a capture to open the same side-by-side review used on the capture record page.
- **Duplicate HCPs**: pairs proposed by `DuplicateScanJob` (button *Run duplicate scan* or script `06`); filters status / hospital / department / minimum score. Pair detail: field-by-field comparison with radio buttons, survivor choice (suggested: the record with more history, else the older one), affiliations, consent status, related records, score explanation. **Merge** (two clicks) or **Not a duplicate** (optional note; the pair is never proposed again; *Re-open pair* undoes it).
- **Merge** (`HcpMergeService`): writes the chosen values on the survivor, folds records that would clash (the duplicate's affiliation to a department the survivor already has; a second attendance at the same event, keeping "no communications" if either declined; duplicate pairs), then `Database.merge` moves consents, captures, candidates, attendances and affiliations. An immutable **`HCP_Merge__c`** keeps who, when, both records' values (JSON), the field choices and the moved-record counts (*Merge history* tab).
- **Consent evidence after a merge**: the evidence hash is never recomputed or rewritten. *Verify evidence* first checks the hash with the consent's current HCP; if it differs, it retries with each Contact Id merged into that HCP (following earlier merges too, from `HCP_Merge__c`) and reports "intact – recorded for HCP X, merged into this HCP on … by …". Consents created before a merge therefore stay verifiable, and the audit chain explains why `Contact__c` changed.
