# Handoff – HCP Congress (consenso e presenze ai congressi)

Stato al 10 novembre 2026. Questo file serve per riprendere il lavoro, da soli o in una nuova sessione Claude.
I dettagli tecnici completi (deploy, setup UI, checklist di test, regole di matching) sono nel [README](README.md):
qui c'è il quadro d'insieme, lo stato e cosa resta da fare.

## 1. Cos'è

Soluzione Salesforce per i congressi medici: registra gli HCP che passano allo stand, il loro **consenso alle
comunicazioni** (opt-in) e la loro **presenza** al congresso.

Tre modi di catturare un HCP, tutti finiscono in un record `Capture__c` (staging):

| Canale | Chi | Dove |
|---|---|---|
| **Rep Hub** | il rep allo stand | Experience Cloud per utenti interni, o tab Lightning *Rep Capture Hub* (LWC `repCaptureHub`) |
| **QR self-scan** | l'HCP dal suo telefono | sito pubblico `…/hcp?e=<CongressId>&ch=qr` (LWC `hcpPublicCapture`) |
| **Kiosk** | l'HCP su un tablet allo stand | stesso sito, `…&mode=kiosk` |

Poi, in automatico (asincrono, Platform Event `Capture_Matching_Request__e`):

1. **Matching** con gli HCP esistenti (`Contact`): match automatico solo su identificativi univoci (HCP scelto dal rep, email identica, numero di iscrizione identico); tutto il resto va in **revisione** (tab *Matching*, coda con candidati ordinati e spiegazione del punteggio); nessun candidato → nuovo HCP.
2. **Consenso** (`Consent__c`): firmato su schermo, double opt-in via email, riusato se già presente, o rifiutato (nessuna comunicazione).
3. **Presenza** (`Event_Attendee__c`): *Registered* (iscritto prima del congresso) → *Attended* al check-in; walk-in noti o nuovi.
4. Stato consenso pronto per **Gigya** (la sincronizzazione è dell'integrazione esistente, qui c'è solo lo stato *Queued* e un "Simulate sync" per la demo).

## 2. Dove sta il codice

Repository GitHub `patrik8585/claude`. **`main` non contiene ancora il codice**: tutto è in PR in bozza, non unite.

| Branch | PR | Contenuto |
|---|---|---|
| `claude/brave-ride-p495qv` | [#1](https://github.com/patrik8585/claude/pull/1) | **Il progetto**: mockup cliccabile (`index.html`) + progetto SFDX (`salesforce/`). È il branch da cui fare deploy e su cui continuare |
| `claude/blissful-archimedes-mzqw8i` | [#4](https://github.com/patrik8585/claude/pull/4) | Questo handoff, sopra #1 |
| `claude/friendly-curie-xh28ns` | [#3](https://github.com/patrik8585/claude/pull/3) | Presentazione `slides/France_CBU_Congress_Solution.pptx` (soluzione per la CBU Francia) |
| `claude/laughing-noether-4mvy21` | [#2](https://github.com/patrik8585/claude/pull/2) | Altro progetto (account page / CR Insight), **non** riguarda i congressi |

Cartelle in `salesforce/`:
- `force-app/` – core: oggetti, Apex, LWC, pagine, permission set (deploy obbligatorio)
- `force-app-extras/` – report, dashboard, layout Contact/Account (deploy separato)
- `force-app-ai/` – estrazione con Prompt Builder (opzionale, oggi non usata dalla pagina)
- `scripts/apex/` – configurazione, dati di esempio, dati di volume, reset
- `destructive/` – una tantum: rimuove dall'org il vecchio duplicate scan / merge

Nomi da ricordare: l'oggetto `Event__c` si chiama **Congress** nell'interfaccia; `Contact` = **HCP**, `Account` = **HCO**
(ospedali e reparti, record type *Hospital* / *Department*) dopo il rename manuale (README §4.5).

## 3. Stato

**Fatto e verificato nell'org** (Developer Edition, alias `dev-consent`), dal tuo deploy:
- Fasi 1–4: data model, matching v2, coda di revisione, consenso e firma, QR/kiosk, Rep Hub, ospedali e reparti, dati di volume e misura dell'accuratezza, iscrizioni pre-congresso e check-in. Tutti i test locali passavano.
- Accuratezza sul set sintetico (DEV): 59/59 catture come atteso, precisione del match automatico 100% (16/16), nessun HCP ricreato.
- Email (double opt-in e copia firmata) verificate.

**Fatto ma da verificare con un deploy** (ultimi commit, 22–26 ottobre):
- Rinomina *Congress*, tab *Matching* senza duplicati/merge, Accuracy per congresso, revisione in modale (con il deploy distruttivo).
- Rep Hub: resta sul congresso, pulsante **New search – next HCP** dopo ogni cattura, campi walk-in vuoti.
- **Therapeutic area** multi-select opzionale (`Capture__c.Therapeutic_Area__c`, 31 valori) nella scheda HCP e nel walk-in, visibile in *My captures today*.

Non so se questi ultimi sono già nell'org: se non ricordi di averli deployati, rifai il deploy (§4).

**Tolto su richiesta del business** (non rimettere senza decisione):
- Duplicate scan e merge degli HCP → i duplicati si gestiscono in **Pitcher**, qui non si modificano i dati master.
- Pulsante "Extract with AI" sulle note → il rep scrive o detta le note; il codice Apex resta (`force-app-ai`).
- Import CSV delle iscrizioni dalla pagina del congresso → solo conteggi live; le iscrizioni si caricano con lo script `09`.
- Campo ospedale nel walk-in → l'ospedale arriva solo da un dominio email istituzionale.

## 4. Come riprendere

```bash
git clone https://github.com/patrik8585/claude.git
cd claude
git checkout claude/brave-ride-p495qv
cd salesforce

sf org login web --alias dev-consent --instance-url https://login.salesforce.com --set-default
sf project deploy start --source-dir force-app --target-org dev-consent --test-level RunLocalTests --wait 30
sf project deploy start --source-dir force-app-extras --target-org dev-consent --wait 30
```

Se l'org ha ancora il duplicate scan (deploy precedente a `b7402f5`), il primo deploy va fatto con il manifest +
`destructive/` (README §3). Dopo un deploy: assegna i permission set (`HCP_Consent_Admin` a te, `HCP_Consent_Rep` ai rep).

Script utili (`sf apex run --file scripts/apex/<nome> --target-org dev-consent`):
`01-configure` · `02-my-territory` · `03-sample-data` · `04-simulate-gigya` · `05-volume-data` ·
`07-regenerate-test-captures` · `09-sample-registrations` · `10-test-email` · `98-cleanup-volume-data` ·
`99-reset-sample-data` · `event-ids` (stampa gli URL QR e kiosk di ogni congresso).

Parti che non si deployano e vanno fatte a mano nel Setup: email/deliverability, sito pubblico e sito per i rep,
utenti, rename Contact/Account, navigazione dell'app (README §4).

**Con Claude**: apri una sessione sul repository `patrik8585/claude`, branch `claude/brave-ride-p495qv`, e parti da:
> Leggi `salesforce/HANDOFF.md` e `salesforce/README.md`. Lavoriamo sul progetto congressi in `salesforce/`.
> [cosa vuoi fare]

Claude non ha accesso all'org: scrive e controlla il codice, tu fai deploy e test e gli incolli gli errori.

## 5. Cose aperte

**PR da sistemare**
- Le PR sono tutte in bozza e niente è su `main`. Quando la soluzione è stabile: unire #1 (e #4) su `main`, e #3 per le slide.

**Decisioni Legal / DPO** (README §7, nessuna presa qui)
- L1 double opt-in via email sufficiente per QR e kiosk in tutti i paesi?
- L2 firma PNG su schermo come evidenza; firma sul kiosk senza rep come testimone?
- L3 HCP che rifiutano salvati come presenti "senza comunicazioni": base legale?
- L4 conferma con click esplicito invece che all'apertura del link.
- L5 retention delle catture e delle note; link alla privacy notice.
- L6 cosa fare con chi ha una versione vecchia del testo di consenso.

**Decisioni IT**
- T1 CAPTCHA sulla pagina pubblica (oggi: honeypot + token firmato + rate limit).
- T2 limiti email giornalieri di Salesforce ai congressi → Marketing Cloud?
- T3 il connettore Gigya legge `Consent__c` così com'è o serve una mappatura verso l'oggetto Pitcher?

**Limiti noti** (README §6)
- Developer Edition: pochissime email al giorno.
- Dettatura vocale non verificata nell'app mobile Salesforce (c'è sempre il microfono della tastiera).
- Un refuso nelle prime 3 lettere del cognome di un HCP di un altro ospedale crea un nuovo HCP (risolto poi in Pitcher).
- CPU del matching con ~1.000 HCP non misurata in produzione.
- Mockup `index.html` fermo al 6 ottobre: non mostra le modifiche successive.

**Possibili prossimi passi**
- Deploy e test degli ultimi commit (§3).
- Therapeutic area: mostrarla anche sul record HCP / nei report, se serve al business.
- Sostituire "Simulate sync" con l'integrazione Gigya reale (T3).
- Portare la soluzione in un'org vera (sandbox): licenze, siti, mittente email di produzione.
