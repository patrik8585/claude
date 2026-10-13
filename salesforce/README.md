# HCP Consent Capture – Salesforce implementation

This is the Salesforce build of the approved clickable mockup (`../index.html`, 7 steps).
It is an SFDX project that **you deploy yourself** to the Agentforce Developer Edition org
(alias `dev-consent`). Nothing here has been deployed or run against an org yet. See
[Known limitations / not verified](#known-limitations--not-verified).

## 1. Phased plan

| Phase | Scope | Status in this repo |
|---|---|---|
| **1** | Data model, async matching, review console, consent record and Gigya status, dashboard and reports, permission sets, sample data | **Code complete**, not yet deployed |
| **2** | Experience Cloud: public QR page, kiosk mode, double opt-in confirmation page, rep page (search first, signature, dictation, rule-based extraction) | **LWCs and Apex complete**. You create the sites in the UI (section 4) |
| **3** | AI with Prompt Builder: "Extract with AI" on notes, review recommendation | Design only (section 8). Phase 1 uses deterministic rules behind the same Apex methods |

### Defaults I chose (change them if you disagree)

- **Objects**: custom objects only (`Capture__c`, `Capture_Candidate__c`, `Consent__c`, `Event__c`, `Event_Attendee__c`), so internal users can be on the **Salesforce Platform** license. HCPs are standard `Contact` records with custom fields. The Account is the HCP's organisation.
- **Async matching**: a `Capture__c` insert publishes the platform event `Capture_Matching_Request__e`. Its subscriber runs as the *Automated Process* user. Guest and rep transactions therefore never create HCPs or consents themselves.
- **Guest security**: the guest user gets **Apex class access only** (no object permissions). `PublicCaptureController` is `without sharing` with strict server-side validation, a honeypot field, an HMAC-signed form token (minimum fill time 3 s, maximum age 4 h) and rate limits (3 per email per event per day, 30 per event per minute). It never returns record Ids. Guest-created captures are re-owned by the **event owner** during matching.
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
│   ├── reports/, dashboards/    # 6 reports + "Capture performance" dashboard
│   └── layouts/Contact-Contact Layout   # REPLACES the default Contact layout (fine on a fresh org)
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
| `ConsentDemoData` | Settings, sample data, reset |

### Matching rules (mockup step 4)

0. Rep picked the HCP from search → **Auto-matched** ("HCP selected by rep")
1. Identical email (case-insensitive) → **Auto-matched**
2. Identical registration number (normalised: uppercase, without `-`, space or `/`) → **Auto-matched**
3. Same surname (namesakes, accent-insensitive) → **To review**: up to 10 candidates in `Capture_Candidate__c` with per-field flags (Exact / Partial / None / Not captured). Scores: full name 30 (surname only 15), email 25, city 15, specialty 15, registration number 15
4. No candidate → **New HCP** (a Contact is created under the organisation's Account, or under "HCPs - organisation unknown")

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

# 2. Reports, dashboard and the Contact layout (separate, so a problem here never blocks the core)
sf project deploy start --source-dir force-app-extras --target-org dev-consent --wait 30

# 3. Permission sets for yourself (admin = everything, both custom permissions)
sf org assign permset --name HCP_Consent_Admin --target-org dev-consent

# 4. Settings, your territory, sample data (run them one by one, in this order)
sf apex run --file scripts/apex/01-configure.apex   --target-org dev-consent
sf apex run --file scripts/apex/02-my-territory.apex --target-org dev-consent
sf apex run --file scripts/apex/03-sample-data.apex  --target-org dev-consent
#    wait ~10 seconds for async matching, then optionally:
sf apex run --file scripts/apex/04-simulate-gigya.apex --target-org dev-consent

# 5. Open the app
sf org open --target-org dev-consent --path lightning/app/c__HCP_Consent_Hub
```

If step 1 fails, paste me the full error output (component name and message) and I will fix it.
To see test results with coverage: `sf apex run test --test-level RunLocalTests --code-coverage --result-format human --target-org dev-consent --wait 20`.

Re-run `01-configure.apex` after creating the public site, with its real URL. Use `scripts/apex/event-ids.apex` to print the QR and kiosk URLs for each event.
To start over: `sf apex run --file scripts/apex/99-reset-sample-data.apex --target-org dev-consent`, then run `03` again.

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
5. Setup → Digital Experiences → All Sites → *HCP Consent* → **Workspaces → Administration → Preferences**: set the **default owner for records created by guest users** to an internal user (required by Salesforce; matching then moves the capture to the event owner).
6. Copy the site URL (e.g. `https://<domain>.my.site.com/hcp`), put it in `scripts/apex/01-configure.apex` and run that script again.
7. URLs:
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
- **Data steward**: license *Salesforce Platform*, profile *Standard Platform User*, permission set **HCP Consent - Data Steward**.
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

**Step 4 – Automatic matching** (after `03-sample-data.apex`)
- [ ] *Captures* → list view **All captures**: 8 Auto-matched (email: Villa, Ferri, Conti, Gallo, Greco; registration number: Romano, Rinaldi, Sala), 2 To review (Maria Bianchi, Roberto Esposito) and 2 New HCP (Leone, Marchetti).

**Step 5 – Review console**
- [ ] List view **To review** shows 2 captures. Open Maria Bianchi: path at "To review"; suggestion "Recommended: Dr. Maria Bianchi - same surname, city and specialty", confidence High; 3 candidates side by side with green/amber cells.
- [ ] **Match** → path moves to Consent created and a consent is linked. Esposito → **Create new HCP** or **Discard** both work, and buttons disappear once resolved.

**Step 6 – Consent record**
- [ ] Open a consent → details (type, channel, method, version, captured by, matched by, source capture, event) plus the Gigya timeline. **Simulate sync (demo)** → "Sent to Gigya ✓" and the capture stage becomes *Sent to Gigya*.
- [ ] HCPs with consent on file (Ferri, Romano, Benedetti) get **no** new consent when reused from the rep page.

**Step 7 – Dashboard**
- [ ] Tab **Capture Dashboard**: KPIs, channel bars, captures per rep, matching and consent donuts. The event filter changes the figures.
- [ ] Reports tab → *HCP Consent Reports* (6 reports). Dashboards tab → *Capture performance*.

## 6. Known limitations / not verified

**Not verified.** I had no org access and no Salesforce compiler, so nothing has been deployed or executed against Salesforce. What I did check locally:
- every Apex file parses (prettier-plugin-apex / jorje parser);
- every LWC compiles with `@lwc/compiler`;
- `sf project convert source` succeeds on both package directories;
- all XML is well-formed;
- a script cross-checks that every field, object, class, tab and LWC referenced by Apex, LWC, layouts, list views, permission sets and flexipages exists in the project.

Semantic Apex errors (types, SOQL against the real schema) and test outcomes are **only verified when you deploy**. Most likely first-deploy issues, which I will fix from the error output:
- flexipage component names or properties (`force:highlightsPanel`, `force:detailPanel`, `force:relatedListContainer`);
- tab `motif` icon names;
- report and dashboard XML in `force-app-extras` (deployed separately on purpose);
- the Contact layout in `force-app-extras` **replaces** "Contact Layout". That is fine on a fresh org; skip that file otherwise.

Functional and platform limits:
- **Email limits**: Apex single emails to external addresses are limited per org per day. On Developer Edition the limit is very small (single digits to ~15/day). In production it is typically 5,000/day. When the limit is reached the capture is still saved with `Confirmation_Email_Status__c = Failed`; there is no automatic resend in phase 1. Use Marketing Cloud or a transactional email service for high volume (open question T2).
- **Bot protection** is honeypot + signed token + rate limits. There is **no CAPTCHA** (reCAPTCHA in LWR needs extra setup; open question T1).
- **Accent-insensitive matching** is done in Apex after a surname query. The SOQL itself is accent-sensitive ("Nicolò" vs "Nicolo" may not be fetched as a candidate).
- Two captures of the **same new HCP in the same batch** create two Contacts (rare; the steward can merge them).
- **Territory** is a plain text field used only to order the rep search (own territory first); it does not restrict visibility.
- **Gigya**: only a status field and timeline. "Simulate sync" is a demo stand-in for the real integration.
- **Dictation** uses the browser Web Speech API (Chrome/Android/Safari). Elsewhere it falls back to keyboard dictation. Extraction rules are English/Italian keyword based (phase 3 replaces them).
- The **slides** are a URL on the event (`Slides_Url__c`), shown after confirmation; no file is emailed.
- **Kiosk**: the device must stay on the page. Use the browser or OS kiosk / guided-access mode.
- Capture records keep the HCP data entered at capture time; they are not deleted after matching (retention period: open question L5).

## 7. Open questions (not decided here)

For Legal / DPO:
- **L1** Is the double opt-in email (no signature) sufficient for the self-scan and kiosk channels in every country concerned? (Compliance approved it for the email flow; please confirm the scope.)
- **L2** On-screen signature as evidence for explicit consent and for re-collecting after an opt-out: is a PNG stored as a Salesforce file, without signer authentication, enough? Is a retention period needed for signatures?
- **L3** Declined HCPs are stored as attendees with "no communications". Is this the right legal basis (legitimate interest / event attendance records)?
- **L4** The confirmation page asks for an explicit click instead of confirming on link open. Please confirm this is acceptable.
- **L5** Retention and deletion of capture (staging) records, including discarded ones, and of rep notes. Is a privacy notice link required on the public form? (The consent text references the Privacy Notice; the URL must be provided.)
- **L6** Consent text versioning: when v3.3 is published, should HCPs with v3.1/v3.2 be asked again?

For IT:
- **T1** CAPTCHA on the public page (Google reCAPTCHA via LWR, or Salesforce bot protection add-ons)?
- **T2** Email volume at congresses vs. Salesforce daily email limits. Should the confirmation email move to Marketing Cloud?
- **T3** Does the existing Gigya connector read `Consent__c` as-is, or do the field names need mapping to the Pitcher object?

## 8. Phase 3 – AI with Prompt Builder (design)

- **Extract with AI**: a Prompt Builder *Flex* template "HCP Notes Extraction" with input `notes`. It returns JSON with the same keys as `NotesExtractionService.Result`. `RepCaptureController.extractFromNotes` calls it via `ConnectApi.EinsteinLLM` / `ConnectApi.EinsteinPromptTemplateGenerations` and falls back to the rule-based extractor on error. The LWC does not change.
- **Review recommendation**: a *Record* template grounded on `Capture__c` and its `Capture_Candidate__c` rows. It writes `Suggestion__c` and `Suggestion_Confidence__c`, which the review LWC already displays. Rules stay authoritative: AI only suggests and a person decides.
- Needs Einstein generative AI enabled on the org (Agentforce Developer Edition includes it) and the Prompt Template user permissions for reps and stewards.
