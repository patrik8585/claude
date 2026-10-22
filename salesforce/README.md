# HCP Consent Capture – Salesforce implementation

This is the Salesforce build of the approved clickable mockup (`../index.html`, 7 steps).
It is an SFDX project that **you deploy yourself** to the Agentforce Developer Edition org
(alias `dev-consent`). Phases 1–4 are deployed and every local test passes. The pre-demo changes
(object *Congress*, *Matching* tab without duplicates and merge, Accuracy per congress, review in a modal,
new app navigation) are deployed with the commands of section 3, including a destructive step that removes
the duplicate scan and the merge from the org. See [Known limitations / not verified](#6-known-limitations--not-verified).

**Names in the UI**: the object `Event__c` is labelled **Congress** (tab *Congresses*); its field labels and the
page texts still say *event*. Standard `Contact` = **HCP** and `Account` = **HCO** after the manual rename of
section 4.5 (API names never change).

## 1. Phased plan

| Phase | Scope | Status in this repo |
|---|---|---|
| **1** | Data model, async matching, review console, consent record and Gigya status, dashboard and reports, permission sets, sample data | **Code complete**, not yet deployed |
| **2** | Experience Cloud: public QR page, kiosk mode, double opt-in confirmation page, rep page (search first, signature, dictation, rule-based extraction) | **LWCs and Apex complete**. You create the sites in the UI (section 4) |
| **3** | AI with Prompt Builder: "Extract with AI" on notes, review recommendation | "Extract with AI" was deployed and verified with Prompt Builder, then **removed from the rep page** on business feedback: the rep keeps typed / dictated notes only. The Apex (`extractFromNotes`, `force-app-ai`) stays for a later decision (section 8). Review recommendation: design only |
| **4** | Hospitals & departments, matching v2 (parametric), volume test data with accuracy measurement, Matching workbench (review queue, accuracy per congress) | **Deployed**, all tests passing; accuracy measured on the DEV volume set (sections 9–12). The duplicate scan and HCP merge were built, then **removed** on business feedback: duplicates are handled in Pitcher and HCP master data is not changed here |

### Defaults I chose (change them if you disagree)

- **Objects**: custom objects only (`Capture__c`, `Capture_Candidate__c`, `Consent__c`, `Event__c`, `Event_Attendee__c`, `HCP_Affiliation__c`), so internal users can be on the **Salesforce Platform** license. HCPs are standard `Contact` records with custom fields. Hospitals and departments are `Account` records (record types `Hospital` / `Department`); `Contact.AccountId` = the HCP's primary department (section 9).
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
│   ├── flexipages/              # Capture / Consent / Congress record pages, Rep Capture Hub, Capture Dashboard, Matching app pages
│   ├── applications/            # Lightning app "HCP Consent Hub"
│   ├── permissionsets/          # HCP_Consent_Admin / _Rep / _Data_Steward / _Guest
│   ├── customPermissions/, customMetadata/, globalValueSets/, layouts/, tabs/
├── force-app-extras/main/default/
│   ├── reports/, dashboards/    # 7 reports + "Capture performance" dashboard
│   └── layouts/                 # Contact Layout + Account Layout: REPLACE the default layouts (fine on a fresh org)
├── force-app-ai/main/default/   # NotesExtractionAI (Prompt Builder call), deployed after the Einstein setup
├── scripts/apex/                # configure, territory, sample data, Gigya simulation, registrations, reset, event URLs
└── destructive/                 # one-off: removes the duplicate scan and the merge from the org (section 3)
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
| `VolumeTestData` | Test only. Batch: hospitals, HCPs with hard cases and test captures with expected outcomes, in two sizes (DEV ~260 HCPs / FULL ~1,000 HCPs); cleanup |
| `MatchingAccuracyController` | Accuracy tab: live matching figures per congress (or all congresses), and precision on the synthetic test captures |
| `MatchingWorkbenchController` | Matching workbench: hospital filter options and the review queue |
| `EventRegistrationService` | Pre-event registrations: live counts for the Congress page card; loads registrations (script 09) |
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

# 1-bis. Once, after step 1 on an org that had the duplicate scan / merge: delete them from the org
#        (DuplicateScanJob, HcpMergeService, HCP_Duplicate_Pair__c, HCP_Merge__c with their records,
#        Matching Setting field Duplicate_Min_Score__c). Skip on a fresh org.
sf project deploy start --manifest destructive/package.xml --post-destructive-changes destructive/destructiveChanges.xml --target-org dev-consent --test-level RunLocalTests --wait 30

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
#    pre-event registrations, 50 per congress and 20 per training meeting (section 13; best after 05):
sf apex run --file scripts/apex/09-sample-registrations.apex --target-org dev-consent
#    wait ~10 seconds for async matching, then optionally:
sf apex run --file scripts/apex/04-simulate-gigya.apex --target-org dev-consent
#    volume test data (~2 minutes, Batch Apex):
sf apex run --file scripts/apex/05-volume-data.apex --target-org dev-consent

# 5. Open the app
sf org open --target-org dev-consent --path lightning/app/c__HCP_Consent_Hub
```

If step 1 fails, paste me the full error output (component name and message) and I will fix it.
To see test results with coverage: `sf apex run test --test-level RunLocalTests --code-coverage --result-format human --target-org dev-consent --wait 20`.

Re-run `01-configure.apex` after creating the public site, with its real URL. Use `scripts/apex/event-ids.apex` to print the QR and kiosk URLs for each event.
To start over: `sf apex run --file scripts/apex/99-reset-sample-data.apex --target-org dev-consent`, then run `03` and `09` again.
**Org already loaded before phase 4**: the mockup HCPs were created without hospitals and departments. Run `99-reset-sample-data.apex` and then `03-sample-data.apex` once after the phase 4 deploy (the reset never touches volume test data).
Volume data: `07-regenerate-test-captures.apex` re-creates only the test captures (after changing matching parameters); `98-cleanup-volume-data.apex` deletes all of it.

## 4. Manual setup in the UI (cannot be deployed reliably as metadata)

### 4.1 Email (needed for double opt-in)
1. Setup → **Deliverability** → Access level = **All email**. In some new orgs it is "System email only", and then every confirmation email shows `Confirmation_Email_Status__c = Failed`.
2. Optional: Setup → **Organization-Wide Addresses** → add and verify e.g. `no-reply@…`. Put the address in Setup → Custom Settings → *Consent Capture Settings* → Manage → *Org-Wide Email Address*.
3. **No email arrives?** Run `sf apex run --file scripts/apex/10-test-email.apex --target-org dev-consent | findstr "EMAIL CHECK"`. It prints the public site URL used in the link, the org-wide address, the daily single-email allowance used, whether Salesforce lets Apex send, sends a test email to your own user address and lists the last captures with their **Email Error** (also on the capture page). Typical causes: Deliverability not *All email* (`NO_MASS_MAIL_PERMISSION`), daily limit reached (a Developer Edition allows only a few external emails a day), no public site URL, an org-wide address that is not verified, or the email sent but filed as spam (check the spam folder: Developer Edition mail comes from a Salesforce relay).
4. **Verified in the Developer Edition**: the emails are sent and reach Gmail **in the spam folder**; corporate mailboxes (`@danone.com`) receive nothing (blocked by the company mail filter). For the demo use a Gmail address and mark the first email *Not spam*. For production the sender must be a verified company domain (Organization-Wide Address + DKIM key for the domain, Setup › DKIM Keys) or a transactional email service / Marketing Cloud (open question T2).

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
7. **QR codes for posters**: open any congress (tab *Congresses*). The record page shows the **booth QR** (self-scan) and the **kiosk QR**, with **Download PNG** (1200 px) / **Download SVG** (vector, best for print) / **Copy link**. Admins and data stewards only.
   URLs behind the codes:
   - QR at the booth: `https://…/hcp?e=<EventId>&ch=qr`
   - Kiosk tablet: `https://…/hcp?e=<EventId>&mode=kiosk`
   - Confirmation link in the email: `https://…/hcp?t=<token>` (generated automatically)

### 4.2-bis The HCP page is reached by scanning the QR
HCPs open the public page only from the booth or kiosk QR of the congress (section 4.2, step 7). The internal Lightning preview page (`HCP_Public_Preview`) is no longer in the app navigation; it still exists for troubleshooting at `/lightning/n/HCP_Public_Preview?c__e=<EventId>` (admins only) but is not part of the demo.

### 4.3 Rep page (Experience Cloud for internal users)
1. Create a second site, **Build Your Own (LWR)**, name `HCP Rep`, URL suffix **`rep`**.
2. Experience Builder → Home → drag **Rep Capture Hub**. Settings → Security & Privacy → **turn off** public access (login required). Publish.
3. Workspaces → Administration → **Members** → add the permission set **HCP Consent - Rep** (and/or the profile *Standard Platform User*). Activate the site.
4. Reps log in at `https://<domain>.my.site.com/rep` with their normal Salesforce username.
5. Shortcut for testing: the same component is the **Rep Capture Hub** tab in the *HCP Consent Hub* app.

### 4.4 Users
- **Rep**: license *Salesforce Platform*, profile *Standard Platform User*, permission set **HCP Consent - Rep**, field **Territory** = `IT-PED-01` for the demo. It only orders search results: the sample HCPs in `IT-PED-01` (Ferri, Romano, Conti, Gallo, Rinaldi, Villa, Greco, Sala, Benedetti) come first, and the others are shown with an "Other territory" badge.
- **Data steward**: license *Salesforce Platform*, profile *Standard Platform User*, permission set **HCP Consent - Data Steward** (Matching tab, affiliations, Account record types Hospital / Department). Stewards cannot delete HCPs: duplicates are handled in Pitcher.
- **Admin / demo**: you, with **HCP Consent - Admin**.
- Reports and dashboard folders are private to you after deploy. Share *HCP Consent Reports* and *HCP Consent Dashboards* with stewards and marketing from the Reports tab (folder → Share).

### 4.5 Rename Contact to "HCP" and Account to "HCO" (manual, once)
Standard objects are renamed in Setup, not by deploy (the Metadata API only carries such renames as translations, which needs the Translation Workbench; the manual way takes two minutes and is reversible).
1. Setup → Quick Find **Rename Tabs and Labels** → Select Language **English**.
2. Row **Contacts** → **Edit**: Singular `HCP`, Plural `HCPs`, tick **Starts with vowel sound** ("an HCP") → **Next** → leave the field labels as proposed → **Save**.
3. Row **Accounts** → **Edit**: Singular `HCO`, Plural `HCOs`, tick **Starts with vowel sound** → **Next** → **Save**. Field labels that contain the object name follow (e.g. *Account Name* → *HCO Name*).
4. Reload the app. The rename applies to the whole org (every app, list views, reports, page titles) in English; other user languages need the same rename in that language.

### 4.6 App navigation
The *HCP Consent Hub* app shows, in this order: **Congresses, Rep Capture Hub, Matching, Captures, Capture Dashboard, HCOs, HCPs, Reports, Dashboards**. Consents are opened from a capture or an HCP (the tab is not in the navigation). If your navigation bar still shows the old order, you personalised it earlier: click the pencil at the right of the bar → **Reset Navigation** (or remove / reorder the items by hand) → Save.

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
- [ ] Search `Bianchi` → the 3 Bianchi namesakes appear with an "Other territory" badge (found anyway). Search `Rossi` → "No HCP found" → **Add as walk-in**. Alternatively, with results on screen, use **Not in the list? + Add as walk-in** → fill in the fields, type or dictate a note → choose a consent option → **Save capture** → *My captures today* lists it with its note.
- [ ] Microphone: on Chrome/Android it dictates. Where the browser has no Web Speech API, a hint asks you to use the keyboard microphone.

**Step 3 – Kiosk**
- [ ] `…/hcp?e=<TrainingId>&mode=kiosk` shows the large two-column layout. After submit the page counts down 6 s and resets. The capture's Channel is Kiosk.
- [ ] Type a name and email, submit, then start typing the same name for the next visitor: the browser offers no suggestion (if it still does, see the kiosk note in section 6).
- [ ] Choose **Sign here on the tablet** → submitting without drawing highlights the box → draw → **Register** → "Your consent is recorded. A copy has been sent to your email." The capture has Consent method *Explicit question + signature*, Opt-in Confirmed, a signature file and `Capture_Device__c` = `Kiosk | …`; after matching its consent is *Opt-in confirmed* with Signature captured and the file is linked to it.

**Step 3-bis – Registered attendees** (after `09-sample-registrations.apex`, section 13)
- [ ] Congress *National Paediatrics Congress 2026 - Milan* › card **Registrations**: 50 registered, a few checked in (Ferri and any registrant already captured at the congress), the rest not arrived. *Infant Nutrition Training - Bologna*: 20 registered. The counts are live: check in an HCP on the rep page and the card changes within 15 seconds (or press Refresh).
- [ ] Rep page › congress › **Show registered list**: not-arrived registrants first (alphabetical; Benedetti, Marta Bianchi, Esposito, Villa among them) with the *Registered* badge, checked-in ones at the bottom. Benedetti → *Consent on file* → **✓ Check in** (no question). Marta Bianchi → no consent → the consent options, buttons say *check in*.

**Step 4 – Automatic matching** (after `03-sample-data.apex`)
- [ ] *Captures* → list view **All captures**: 8 Auto-matched (email: Villa, Ferri, Conti, Gallo, Greco; registration number: Romano, Rinaldi, Sala), 2 To review (Maria Bianchi, Roberto Esposito) and 2 New HCP (Leone, Marchetti).

**Step 5 – Review console**
- [ ] List view **To review** shows 2 captures. Open Maria Bianchi: path at "To review"; box *Suggested match* (rule-based Apex score, no AI) "Recommended: Dr. Maria Bianchi - same surname, city and specialty", confidence High; 3 candidates side by side with green/amber cells.
- [ ] **Match** → path moves to Consent created and a consent is linked. Esposito → **Create new HCP** or **Discard** both work, and buttons disappear once resolved.

**Step 6 – Consent record**
- [ ] Open a consent → details (type, channel, method, version, captured by, matched by, source capture, event) plus the Gigya timeline. **Simulate sync (demo)** → "Sent to Gigya ✓" and the capture stage becomes *Sent to Gigya*.
- [ ] HCPs with consent on file (Ferri, Romano, Benedetti) get **no** new consent when reused from the rep page.

**Phase 4 – Hospitals, matching v2, Matching workbench** (after `99` + `03`, then `05`)
- [ ] HCOs → *Gaslini Institute*: record type Hospital, related list *HCP Affiliations*. Dr. Maria Bianchi (Genoa): Account = *Paediatrics - Gaslini Institute*, related list *Affiliations*.
- [ ] Mockup capture of Maria Bianchi: Hospital = Gaslini Institute (resolved from "Gaslini"), confidence High; the comparison table has the rows *Hospital / department* and *Why this score*.
- [ ] Rep page: search `Rinaldi` → the card shows hospital, department and "Also works in". The walk-in form has no hospital field (business decision): the hospital of a walk-in comes from an institutional email domain, if any.
- [ ] Tab **Matching** › *Review queue*: tick 2 captures → **Match to recommended** → Confirm → they leave the queue. Scroll down the list, click a capture name → the side-by-side review opens **in a window over the list** (the list keeps its position), with *(n of N)*, **‹ Previous / Next ›** and **← Back to queue** (or Esc). **Match** → the window moves on to the next capture; after the last one it closes.
- [ ] *Accuracy* › **All congresses** (default): captures by channel, auto-matched (by rep / email / registration number), sent to review, review backlog with the oldest wait, reviewed (matched / new HCP / discarded, average time to decide), recommendation accepted, confidence of the review suggestions, new HCPs, registrations not found, queued / errors, and a table by congress (click a name to filter). Choose one congress in the selector: same figures for that congress only. Capture an HCP on the rep page or resolve a capture in the queue: the figures change within 15 seconds.
- [ ] *Accuracy* › **Test set (synthetic, with expected outcomes)**: 59 test captures (DEV; 150 with FULL), auto-match precision, review rate, false new-HCP rate, table by test case. After changing a weight in Setup › Custom Metadata Types › Matching Setting › Default, run `07-regenerate-test-captures.apex`, wait about a minute: the figures change.
- [ ] Dictation on Chrome (desktop or Android): tap 🎤, speak, pause a few seconds: dictation continues and shows the interim text; the IT/EN chip switches language. Block the microphone in the site settings → a message explains how to allow it or use the keyboard microphone.

**Step 7 – Dashboard**
- [ ] Tab **Capture Dashboard**: KPIs, channel bars, captures per rep, matching and consent donuts. The event filter changes the figures.
- [ ] Reports tab → *HCP Consent Reports* (7 reports). Dashboards tab → *Capture performance*.

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
- CPU time of the matching transaction with ~1,000 HCPs (expected well within limits, not measured);
- the Account layout in `force-app-extras` **replaces** "Account Layout", like the Contact layout. Fine on a fresh org; skip those files otherwise;
- `force-app-ai`: the `ConnectApi` Prompt Builder types (only compiled by Salesforce, never locally).

Functional and platform limits:
- **Email limits**: Apex single emails to external addresses are limited per org per day. On Developer Edition the limit is very small (single digits to ~15/day). In production it is typically 5,000/day. When the limit is reached the capture is still saved with `Confirmation_Email_Status__c = Failed`; there is no automatic resend in phase 1. Use Marketing Cloud or a transactional email service for high volume (open question T2).
- **Bot protection** is honeypot + signed token + rate limits. There is **no CAPTCHA** (reCAPTCHA in LWR needs extra setup; open question T1).
- **Candidate retrieval** uses the first 3 letters of surname and first name, the email, the registration number and the capture's hospital. A typo in the **first 3 letters** of the surname of an HCP from another hospital is not found (it becomes a New HCP; such duplicates are resolved in Pitcher). Accent-insensitivity is applied in Apex, after retrieval.
- **No duplicate management here**: duplicate HCPs are detected and merged in Pitcher (business decision). The matching still protects against new duplicates: an email or registration number shared by several HCPs goes to review, never auto-matched.
- **Record types**: the admin and steward permission sets grant Hospital / Department. If your profile has record type restrictions, also make them available on the profile.
- Two captures of the **same new HCP in the same batch** create two Contacts (rare; resolved in Pitcher like any other duplicate).
- **Territory** is a plain text field used only to order the rep search (own territory first); it does not restrict visibility.
- **Gigya**: only a status field and timeline. "Simulate sync" is a demo stand-in for the real integration.
- **Dictation** uses the browser Web Speech API (Chrome / Edge / Android / Safari) with auto-restart after pauses, interim text, an IT/EN language switch and explicit microphone-permission messages. Firefox and some in-app browsers have no Web Speech API: the page then asks to use the keyboard microphone. Not verified inside the Salesforce mobile app (its WebView may not expose the API) nor in every LWR + Lightning Web Security combination; the keyboard fallback always works.
- **Matching transactions**: the platform-event subscriber processes at most 50 captures per transaction (`PlatformEventSubscriberConfig`), to stay within limits at congress peaks and for the test captures.
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

**Status: not on the rep page.** After the demo review the button was removed: the walk-in keeps the notes field (typed or dictated), saved on the capture and shown in *My captures today* and on the capture record. The Apex method `RepCaptureController.extractFromNotes`, the services and `force-app-ai` are kept, tested and unused; putting the button back is a UI change only. The steps below describe how it was set up and verified.

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

Verified in the Developer Edition: the `ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate` call (inputs `Input:notes` / `Input:today`) returns one JSON object for the demo note, the rep page shows *(Prompt Builder)* and fills all fields, including the task due on Mon 2 Nov 2026. A fast, inexpensive model is enough; the model is set on the template, so it can change without a deploy. Einstein requests consume the org's generative AI allowance. The review recommendation with a Record template remains design only: rules stay authoritative, AI only suggests.

## 9. Hospitals and departments (HCOs)

- `Account` record types **Hospital** and **Department**. A department's `ParentId` is its hospital and `Department_Type__c` its type (Paediatrics, Neonatology, Neonatal Intensive Care, Paediatric Gastroenterology, …). Hospitals carry `Email_Domain__c` (institutional domains, comma separated), `Aliases__c` (other names, semicolon separated) and `OneKey_Workplace_Id__c`.
- **`HCP_Affiliation__c`** (junction): HCP (master-detail to Contact) · Department / Hospital (`HCO__c`) · Role · Primary · Start / End date · formulas Active, Hospital, Department · unique `Affiliation_Key__c` (no duplicate affiliation).
- The trigger keeps **exactly one primary affiliation per HCP** (the one just marked primary wins; when the primary is deleted or ended, the most recent active one is promoted) and sets **`Contact.AccountId` = the primary HCO**.
- Why a custom junction and not `AccountContactRelation`: ACR needs "Contacts to Multiple Accounts" switched on by hand before any deploy that references it, forces the direct relation to equal `AccountId`, and gives less control over keys, validation and merge behaviour. The custom object deploys as metadata, works with the Platform license, is reparented automatically by `Database.merge`, and can be replaced by ACR later if standard ACR reporting becomes a requirement.
- Permission sets: Account record types visible for admin and steward; affiliations read-only for reps, editable for stewards.

## 10. Matching parameters (Custom Metadata)

Setup › Custom Metadata Types › **Matching Setting** › Manage Records › **Default** › Edit. Changes apply to the next capture matched (no deploy). Fields: the weights listed in section 2, *Penalty: registration numbers differ*, *Max edit distance* (short / long names) and *Long name length*, *Minimum candidate score*, *High confidence score* and *gap*, *Maximum candidates per capture*, *Auto-match on identical email*, *Auto-match on identical reg. number*, *Review on conflicting evidence*, *Personal email domains*. An empty field falls back to the built-in default. A Custom Metadata Type was chosen over a Custom Setting because it deploys with the code, is versioned in git, is visible in Apex tests without DML and can still be changed in Setup.

## 11. Volume test data and accuracy

`VolumeTestData` (Batch Apex, one step per transaction, fixed random seed, so every run creates the same data).

**Two sizes.** A Developer Edition has **5 MB of data storage** and Salesforce counts about 2 KB per record whatever its content, so the full set (~3,500 records with affiliations and capture candidates, about 7 MB) does not fit: it pushed the org to 145%, and an org over its limit refuses new records.

| Size | How | Hospitals | Departments | HCPs | Duplicates | Namesakes | Test captures | Storage |
|---|---|---|---|---|---|---|---|---|
| **DEV** (default) | `05-volume-data.apex` = `VolumeTestData.generate()` | 10 (every third of the list) | ~55 | ~260 | 15 | 10 | 59 | ~2 MB |
| **FULL** | `VolumeTestData.generate('FULL')` (sandbox) | 30 | ~170 | ~1,000 | 30 | 25 | 150 | ~7 MB |

The cleanup empties the deleted test records from the Recycle Bin. `regenerateCaptures()` detects the size from the hospitals in the org. The numbers below are for FULL; DEV keeps every hard case and every test case with fewer records.
- 30 Italian hospitals (fictitious `-example.it` domains; two share the name "Ospedale Santa Maria della Misericordia", in Udine and Perugia), each with 3–8 departments; ~1,000 HCPs with Italian names (some with accents or apostrophes), the specialty of their department, city, registration number (85%), OneKey ID, institutional (65%) / personal (20%) / no email, ~10% in 2 departments.
- Hard cases: 25 namesakes in other cities and 30 **real duplicates** (same email with the accent dropped; personal email and registration number typed differently; swapped names; surname typo; moved to another hospital), marked with `Contact.Test_Duplicate_Of__c`.
- 150 test captures (event "Matching accuracy test set (synthetic)", inactive) in 14 test cases with `Expected_Outcome__c` / `Expected_Contact__c` / `Test_Case__c`: exact email, registration number in another format, personal email + hospital, surname typo, accent variant, swapped names, namesake, really new HCP, new HCP with an existing surname, email of a duplicate record, email shared by duplicates, new address at the same institution, email/registration conflict, typo without hospital.
- The mockup surnames are not used, so the mockup demo keeps its outcomes; mockup HCPs and events are never touched. Every generated record carries `Test_Data_Set__c` (`VOLUME`, `VOLUME-CAPTURES`) and is removed by the cleanup.

**Accuracy on the test set** (Matching › Accuracy › *Test set*, and the report *Matching accuracy - test captures*): auto-match precision (auto-matched to the right HCP or to a known duplicate record of it), review rate, false new-HCP rate (a new Contact created for an HCP that exists), right HCP among the review candidates and as the recommendation, outcome as expected per test case, and the captures to look at. **Measured** on the DEV set: 59/59 test captures as expected; auto-match precision 100% (16/16); no HCP created again; right HCP among the review candidates and recommended first 100%; review rate 56% (the test set is built mostly from ambiguous cases). Only synthetic captures carry an expected outcome; real congresses are measured with the live figures of section 12.

## 12. Matching workbench (data stewards)

Tab **Matching** (app page with the `matchingWorkbench` LWC):
- **Review queue**: captures *To review* with hospital, recommended HCP, score and confidence; filters hospital / confidence; bulk **Match to recommended / Create new HCPs / Discard** (max 50, with confirmation). Clicking a capture opens the same side-by-side review used on the capture record page **in a modal window over the list** (no scrolling: the list keeps its position), with *(n of N)*, **Previous / Next**, **Back to queue** and Esc. After *Match*, *Create new HCP* or *Discard* the queue reloads and the window shows the next capture; it closes after the last one.
- **Accuracy**, selector **Congress**:
  - **All congresses** (default) or **one congress**: live figures from the real captures (the synthetic test event is excluded), refreshed every 15 seconds while the page is open, so captures made during the demo appear at once. Figures: *Captures* (by channel), *Auto-matched* (% of processed, by rule: HCP selected by rep / identical email / identical registration number), *Sent to review* (% of processed: still to review + reviewed), *Review backlog* (still to review, oldest waiting time), *Reviewed* (matched / new HCP / discarded, average time from capture to decision), *Recommendation accepted* (reviewed matches where the steward chose the HCP the engine recommended first: the precision proxy for real data), *Confidence* (average score of the recommended HCP; High / Medium / Low), *New HCP (automatic)* (no candidate), *Registration not found* (registrant not in Salesforce), *Queued / errors*. With *All congresses* a table gives the same figures per congress.
  - **Test set (synthetic, with expected outcomes)**: precision against the expected outcome (section 11). Test data is managed with the scripts `05` (generate), `07` (regenerate the test captures after a parameter change) and `98` (delete); there are no buttons in the page.
- *Processed* = all captures except those still queued or in error.

## 13. Registered attendees (pre-event registrations)

Three cases at every event, on every channel (rep page, kiosk, QR self-scan):

| Case | Before the event | At the event |
| --- | --- | --- |
| (a) Walk-in, not in Salesforce | nothing | capture → matching finds no candidate → new HCP, attendee *Attended* |
| (b) HCP in Salesforce, not registered | nothing | capture → matched to the HCP, attendee *Attended* (not registered) |
| (c) HCP registered for the event (always an HCP already in Salesforce) | registration imported → attendee *Registered* | rep **Check in**, kiosk or QR → attendee *Attended*, still flagged *Registered* |

- **Loading registrations**: `EventRegistrationService.register(eventId, rows)` (used by `09-sample-registrations.apex` for the demo; the future feed from the registration website will call the same method). There is no CSV import in the UI. Loading the same registrant twice is skipped (same email, or same name when there is no email).
- **Congress page › card Registrations**: live counts read from the attendees (registered, checked in, not arrived, walk-ins, registrations not in Salesforce, registrations still being matched), refreshed every 15 seconds and with **Refresh**.
- **How it works**: each row becomes a `Capture__c` with Channel **Event registration** and goes through the normal matching (auto-match, or steward review: registrations to review appear in the review queue). **Only HCPs already in Salesforce can be registered**: a row that matches nobody is discarded (rule *Registration - HCP not in Salesforce*, counted on the card), never turned into a new HCP; *Create new HCP* is refused for registrations in the review console and skipped by the bulk action. Matching creates the `Event_Attendee__c` with *Attendance Status = Registered* and **`Registered__c` = true**. Any later capture of that HCP at the event (rep check-in, kiosk, QR) sets *Attended*; `Registered__c` stays true, so the card and the dashboard show *registered → checked in* and *walk-ins* (attended, not registered). A registration imported after the HCP attended never turns *Attended* back into *Registered*.
- **Consent rule**: consent ticked on the registration website is imported as a confirmed `Consent__c` (Channel *Event registration*, method *Given at event registration*, consent text version from the file or the active one). **A registration or an event capture without consent never removes a consent the HCP already has**: only an explicit opt-out (withdrawal) does. The attendee's *Communications Allowed* is true when the HCP gives consent or already has a confirmed one.
- **Attendee Type** (formula on `Event_Attendee__c`, shown in the event's attendee list): *Registered* (imported registration; with *Attendance Status* telling whether the HCP came), *Walk-in - known HCP* (already in Salesforce, not registered) or *Walk-in - new HCP* (created from the event capture).
- **Rep page**: after choosing the event, a bar shows *N registered · M checked in* and **Show registered list** (not yet checked in first). Search results carry a *Registered* / *Checked in* badge; for a registered HCP the button says **✓ Check in**.
- **Matching**: a candidate registered for the capture's event gets **+10** (*registered for this event*, Custom Metadata field *Weight: registered for the event*). It only helps the review suggestion: auto-match still needs an identical email or registration number.
- **Dashboard**: registration captures are not counted as event captures; a KPI shows *Registered → checked in*. The standard report *Captures by channel* (force-app-extras) does list the *Event registration* channel.
- **Sample registrations** (`09-sample-registrations.apex`, run after `05`): every event except the volume test event gets 50 registrants (20 for a *Training meeting*), all HCPs already in Salesforce (the volume HCPs; without volume data, the mockup HCPs): about 85% with their own email, 15% with a personal email and their registration number; about 40% tick the consent. Opted-out HCPs and known duplicate pairs are not used. About 140 records (≈0.3 MB) for the two sample events.
- Not built: removing a registration, a "no-show" status, and the automatic feed from the registration website.
