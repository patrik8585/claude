/**
 * One-off setup and sample data (same data as the clickable mockup).
 *
 *   ConsentDemoData.configure('https://<your-domain>.my.site.com/hcp');  // settings + form secret
 *   ConsentDemoData.setMyTerritory();                                    // separate transaction (User is a setup object)
 *   ConsentDemoData.run();                                               // HCPs, events, consents, captures
 *   ConsentDemoData.simulateGigyaSync();                                 // marks queued consents as sent
 *   ConsentDemoData.reset();                                             // deletes the sample data
 *
 * Captures are matched asynchronously (platform event) a few seconds after run().
 */
public with sharing class ConsentDemoData {
    public static final String TERRITORY_REP = 'IT-PED-01';
    public static final String TERRITORY_OTHER = 'IT-PED-02';
    public static final String CONGRESS_NAME = 'National Paediatrics Congress 2026 - Milan';
    public static final String TRAINING_NAME = 'Infant Nutrition Training - Bologna';
    private static final String DEMO_NOTE = 'Dr. Maria Bianchi, paediatrician at Gaslini Genoa, interested in product X, call back in November. Email maria.bianchi@gmail.com';

    /** Mockup organisations as hospitals: name, city, institutional email domain, aliases. */
    public static final List<List<String>> MOCKUP_HOSPITALS = new List<List<String>>{
        new List<String>{ 'Policlinico di Milano', 'Milan', 'policlinico-example.it', 'Policlinico Milano; Ospedale Maggiore Policlinico' },
        new List<String>{ 'Ospedale Bambino Gesù', 'Rome', null, 'Bambino Gesu; OPBG' },
        new List<String>{ 'AOSP Sant’Orsola', 'Bologna', 'aosp-example.it', 'Sant Orsola; Policlinico Sant Orsola; S. Orsola' },
        new List<String>{ 'Gaslini Institute', 'Genoa', 'gaslini-example.it', 'Gaslini; Istituto Gaslini; IRCCS Giannina Gaslini' },
        new List<String>{ 'San Raffaele Hospital', 'Milan', 'sanraffaele-example.it', 'San Raffaele; Ospedale San Raffaele; HSR' },
        new List<String>{ 'ASL 3 Genovese', 'Genoa', 'asl3-example.it', 'ASL3; ASL 3 Genova' },
        new List<String>{ 'Regina Margherita', 'Turin', null, 'Ospedale Regina Margherita; OIRM' },
        new List<String>{ 'Meyer Children’s', 'Florence', 'meyer-example.it', 'Meyer; AOU Meyer; Ospedale Meyer' },
        new List<String>{ 'Santobono Pausilipon', 'Naples', 'santobono-example.it', 'Santobono; AORN Santobono' },
        new List<String>{ 'ASL Roma 1', 'Rome', 'aslroma-example.it', 'ASL Roma1' },
        new List<String>{ 'AOUI Verona', 'Verona', 'aovr-example.it', 'Borgo Trento; AOUI VR; Ospedale Borgo Trento' },
        new List<String>{ 'ASST Fatebenefratelli', 'Milan', 'asst-example.it', 'Fatebenefratelli; Fatebenefratelli Sacco' },
        new List<String>{ 'ASST Papa Giovanni XXIII', 'Bergamo', 'asst-bg-example.it', 'Papa Giovanni; Ospedale Papa Giovanni XXIII' },
        new List<String>{ 'Azienda Ospedale Padova', 'Padua', null, 'Ospedale di Padova; AOPD' }
    };

    /** Department type for an HCP specialty. */
    public static String departmentTypeFor(String specialty) {
        if (specialty == 'Gynaecology') {
            return 'Obstetrics & Gynaecology';
        }
        if (specialty == 'Dietetics & Nutrition') {
            return 'Clinical Nutrition';
        }
        if (specialty == 'Neonatology' || specialty == 'Paediatric Gastroenterology' || specialty == 'Paediatric Allergy') {
            return specialty;
        }
        return 'Paediatrics';
    }

    public class DemoException extends Exception {
    }

    // ------------------------------------------------------------ settings

    public static void configure(String publicSiteUrl) {
        Consent_Capture_Settings__c s = Consent_Capture_Settings__c.getOrgDefaults();
        if (s == null || s.Id == null) {
            s = new Consent_Capture_Settings__c(SetupOwnerId = UserInfo.getOrganizationId());
        }
        if (String.isBlank(s.Form_Secret__c)) {
            s.Form_Secret__c = EncodingUtil.convertToHex(Crypto.generateAesKey(256)).left(64);
        }
        if (String.isNotBlank(publicSiteUrl)) {
            s.Public_Site_Url__c = publicSiteUrl.trim().removeEnd('/');
        }
        if (s.Max_Per_Email_Per_Day__c == null) {
            s.Max_Per_Email_Per_Day__c = 3;
        }
        if (s.Max_Per_Event_Per_Minute__c == null) {
            s.Max_Per_Event_Per_Minute__c = 30;
        }
        if (s.Min_Form_Seconds__c == null) {
            s.Min_Form_Seconds__c = 3;
        }
        if (s.Token_Validity_Days__c == null) {
            s.Token_Validity_Days__c = 30;
        }
        if (String.isBlank(s.Email_Sender_Name__c)) {
            s.Email_Sender_Name__c = 'Danone Events';
        }
        upsert s;
        ConsentCaptureConfig.resetCache();
    }

    /** Puts the running user in the demo rep territory. Run on its own (mixed DML with data inserts). */
    public static void setMyTerritory() {
        update new User(Id = UserInfo.getUserId(), Territory__c = TERRITORY_REP);
    }

    // ------------------------------------------------------------ sample data

    public static void run() {
        if (![SELECT Id FROM Event__c WHERE Name IN (:CONGRESS_NAME, :TRAINING_NAME) LIMIT 1].isEmpty()) {
            throw new DemoException('Sample data already loaded. Run ConsentDemoData.reset() first.');
        }
        if (String.isBlank(ConsentCaptureConfig.settings().Form_Secret__c)) {
            configure(null);
        }
        Database.DMLOptions dml = CaptureResolutionService.allowDuplicates();

        // HCPs (id, first, last, email, specialty, city, organisation, reg no, OneKey, in rep territory)
        List<List<Object>> hcps = new List<List<Object>>{
            new List<Object>{ 'H1', 'Marco', 'Ferri', 'marco.ferri@policlinico-example.it', 'Paediatrics', 'Milan', 'Policlinico di Milano', 'MI-20418', 'WITA00418201', true },
            new List<Object>{ 'H2', 'Giulia', 'Romano', 'g.romano@ospedale-example.it', 'Neonatology', 'Rome', 'Ospedale Bambino Gesù', 'RM-33102', 'WITA00331020', true },
            new List<Object>{ 'H3', 'Paolo', 'Conti', 'paolo.conti@aosp-example.it', 'Paediatrics', 'Bologna', 'AOSP Sant’Orsola', 'BO-09821', 'WITA00098214', true },
            new List<Object>{ 'H4', 'Maria', 'Bianchi', 'm.bianchi@gaslini-example.it', 'Paediatrics', 'Genoa', 'Gaslini Institute', 'GE-11873', 'WITA00118733', false },
            new List<Object>{ 'H5', 'Maria', 'Bianchi', 'maria.bianchi@sanraffaele-example.it', 'Gynaecology', 'Milan', 'San Raffaele Hospital', 'MI-15530', 'WITA00155305', false },
            new List<Object>{ 'H6', 'Marta', 'Bianchi', 'marta.bianchi@asl3-example.it', 'Paediatrics', 'Genoa', 'ASL 3 Genovese', 'GE-12044', 'WITA00120440', false },
            new List<Object>{ 'H7', 'Alessandro', 'Gallo', 'alessandro.gallo@ospedale-example.it', 'Paediatrics', 'Turin', 'Regina Margherita', 'TO-30417', 'WITA00304177', true },
            new List<Object>{ 'H8', 'Chiara', 'Rinaldi', 'crinaldi@meyer-example.it', 'Paediatric Gastroenterology', 'Florence', 'Meyer Children’s', 'FI-08877', 'WITA00088779', true },
            new List<Object>{ 'H9', 'Roberto', 'Esposito', 'r.esposito@santobono-example.it', 'Paediatric Gastroenterology', 'Naples', 'Santobono Pausilipon', 'NA-27711', 'WITA00277114', false },
            new List<Object>{ 'H10', 'Roberto', 'Esposito', 'roberto.esposito@aslroma-example.it', 'Paediatrics', 'Rome', 'ASL Roma 1', 'RM-19904', 'WITA00199043', false },
            new List<Object>{ 'H11', 'Andrea', 'Villa', 'andrea.villa@aovr-example.it', 'Paediatrics', 'Verona', 'AOUI Verona', 'VR-05530', 'WITA00055302', true },
            new List<Object>{ 'H12', 'Elena', 'Greco', 'elena.greco@asst-example.it', 'Paediatrics', 'Milan', 'ASST Fatebenefratelli', 'MI-22764', 'WITA00227645', true },
            new List<Object>{ 'H13', 'Matteo', 'Sala', 'm.sala@asst-bg-example.it', 'Paediatrics', 'Bergamo', 'ASST Papa Giovanni XXIII', 'BG-04412', 'WITA00044126', true },
            new List<Object>{ 'H14', 'Laura', 'Benedetti', 'laura.benedetti@ospedale-example.it', 'Paediatrics', 'Padua', 'Azienda Ospedale Padova', 'PD-13350', 'WITA00133509', true }
        };

        // Hospitals (record type Hospital) with their departments; each HCP works in the department of its specialty.
        Map<String, Account> hospitals = new Map<String, Account>();
        for (List<String> h : MOCKUP_HOSPITALS) {
            Account a = new Account(
                Name = h[0],
                BillingCity = h[1],
                Email_Domain__c = h[2],
                Aliases__c = h[3],
                RecordTypeId = HcoDirectory.recordTypeId(HcoDirectory.RT_HOSPITAL)
            );
            a.setOptions(dml);
            hospitals.put(h[0], a);
        }
        Database.insert(hospitals.values(), dml);
        Map<String, Account> departments = new Map<String, Account>();
        for (List<Object> h : hcps) {
            String org = (String) h[6];
            for (String deptType : new List<String>{ 'Paediatrics', 'Neonatology', departmentTypeFor((String) h[4]) }) {
                String k = org + '|' + deptType;
                if (!departments.containsKey(k)) {
                    Account d = new Account(
                        Name = deptType + ' - ' + org,
                        ParentId = hospitals.get(org).Id,
                        BillingCity = hospitals.get(org).BillingCity,
                        Department_Type__c = deptType,
                        RecordTypeId = HcoDirectory.recordTypeId(HcoDirectory.RT_DEPARTMENT)
                    );
                    d.setOptions(dml);
                    departments.put(k, d);
                }
            }
        }
        Database.insert(departments.values(), dml);
        HcoDirectory.reset();

        Map<String, Contact> contacts = new Map<String, Contact>();
        for (List<Object> h : hcps) {
            String org = (String) h[6];
            Contact c = new Contact(
                FirstName = (String) h[1],
                LastName = (String) h[2],
                Email = (String) h[3],
                Specialty__c = (String) h[4],
                MailingCity = (String) h[5],
                AccountId = departments.get(org + '|' + departmentTypeFor((String) h[4])).Id,
                Registration_Number__c = (String) h[7],
                OneKey_Id__c = (String) h[8],
                Territory__c = ((Boolean) h[9]) ? TERRITORY_REP : TERRITORY_OTHER,
                Consent_Status__c = CaptureConstants.HCP_NONE
            );
            c.setOptions(dml);
            contacts.put((String) h[0], c);
        }
        Database.insert(contacts.values(), dml);
        List<HCP_Affiliation__c> affiliations = new List<HCP_Affiliation__c>();
        for (List<Object> h : hcps) {
            Contact c = contacts.get((String) h[0]);
            affiliations.add(new HCP_Affiliation__c(Contact__c = c.Id, HCO__c = c.AccountId, Primary__c = true, Role__c = 'Consultant', Start_Date__c = Date.newInstance(2020, 1, 1)));
        }
        // Chiara Rinaldi also works in the general paediatrics department (an HCP in 2 departments).
        affiliations.add(
            new HCP_Affiliation__c(
                Contact__c = contacts.get('H8').Id,
                HCO__c = departments.get('Meyer Children’s|Paediatrics').Id,
                Primary__c = false,
                Role__c = 'Consultant',
                Start_Date__c = Date.newInstance(2023, 9, 1)
            )
        );
        insert affiliations;

        // Existing consents (as created by Pitcher today) and one opt-out.
        List<Consent__c> legacy = new List<Consent__c>{
            legacyConsent(contacts.get('H1').Id, Date.newInstance(2025, 3, 12), 'v3.1', false),
            legacyConsent(contacts.get('H2').Id, Date.newInstance(2025, 9, 2), 'v3.1', false),
            legacyConsent(contacts.get('H14').Id, Date.newInstance(2026, 1, 21), 'v3.2', false),
            legacyConsent(contacts.get('H3').Id, Date.newInstance(2025, 6, 8), 'v3.1', true)
        };
        for (Consent__c k : legacy) {
            k.Evidence_Hash__c = ConsentService.evidenceHash(k);
        }
        insert legacy;
        Set<Id> contactIds = new Set<Id>();
        for (Contact c : contacts.values()) {
            contactIds.add(c.Id);
        }
        ConsentService.refreshContactSummary(contactIds);

        Event__c congress = new Event__c(
            Name = CONGRESS_NAME,
            Short_Name__c = 'Paediatrics Congress',
            Event_Type__c = 'Congress',
            Start_Date__c = Date.newInstance(2026, 10, 14),
            End_Date__c = Date.newInstance(2026, 10, 16),
            Location__c = 'Danone booth · Hall 2',
            Active__c = true,
            Public_Capture_Enabled__c = true,
            Slides_Url__c = 'https://www.example.com/slides/paediatrics-congress-2026.pdf'
        );
        Event__c training = new Event__c(
            Name = TRAINING_NAME,
            Short_Name__c = 'Bologna Training',
            Event_Type__c = 'Training meeting',
            Start_Date__c = Date.newInstance(2026, 10, 13),
            End_Date__c = Date.newInstance(2026, 10, 13),
            Location__c = 'Bologna',
            Active__c = true,
            Public_Capture_Enabled__c = true,
            Slides_Url__c = 'https://www.example.com/slides/infant-nutrition-training.pdf'
        );
        insert new List<Event__c>{ congress, training };

        // Captures (mockup CAP-0001..0012)
        ConsentCaptureConfig.ConsentText text = ConsentCaptureConfig.activeConsentText();
        List<Capture__c> caps = new List<Capture__c>{
            cap(training, 13, '10:42', 'Francesca', 'Leone', 'francesca.leone@gmail.com', 'Dietetics & Nutrition', 'Bologna', null, null, 'Kiosk', null, false),
            cap(training, 13, '11:15', 'Andrea', 'Villa', 'andrea.villa@aovr-example.it', 'Paediatrics', 'Verona', null, null, 'Kiosk', null, true),
            cap(congress, 15, '09:12', 'Marco', 'Ferri', 'marco.ferri@policlinico-example.it', 'Paediatrics', 'Milan', null, null, 'Self-scan', null, true),
            cap(congress, 15, '09:40', 'Giulia', 'Romano', 'giulia.romano@gmail.com', 'Neonatology', 'Rome', 'RM-33102', null, 'Rep', 'Anna Colombo', true),
            cap(congress, 15, '10:05', 'Paolo', 'Conti', 'paolo.conti@aosp-example.it', 'Paediatrics', 'Bologna', null, null, 'Self-scan', null, false),
            cap(congress, 15, '10:31', 'Maria', 'Bianchi', 'maria.bianchi@gmail.com', 'Paediatrics', 'Genoa', null, 'Gaslini', 'Rep', 'Anna Colombo', true),
            cap(congress, 15, '10:58', 'Alessandro', 'Gallo', 'alessandro.gallo@ospedale-example.it', 'Paediatrics', 'Turin', null, null, 'Self-scan', null, true),
            cap(congress, 15, '11:20', 'Chiara', 'Rinaldi', 'chiara.rinaldi@gmail.com', 'Paediatric Gastroenterology', 'Florence', 'FI-08877', null, 'Self-scan', null, false),
            cap(congress, 15, '11:47', 'Roberto', 'Esposito', 'r.esposito@gmail.com', 'Paediatric Gastroenterology', 'Naples', null, null, 'Self-scan', null, false),
            cap(congress, 15, '12:15', 'Silvia', 'Marchetti', 'silvia.marchetti@gmail.com', 'Paediatrics', 'Brescia', null, null, 'Rep', 'Davide Ricci', true),
            cap(congress, 15, '12:48', 'Elena', 'Greco', 'elena.greco@asst-example.it', 'Paediatrics', 'Milan', null, null, 'Rep', 'Sara Fontana', true),
            cap(congress, 15, '13:20', 'Matteo', 'Sala', 'matteo.sala@gmail.com', 'Paediatrics', 'Bergamo', 'BG-04412', null, 'Rep', 'Davide Ricci', false)
        };
        caps[3].Notes__c = 'Asked for the neonatal range samples.';
        caps[5].Notes__c = DEMO_NOTE;
        caps[5].Interest__c = 'Product X';
        caps[9].Notes__c = 'Met at the booth, new in the area.';
        for (Capture__c c : caps) {
            c.Consent_Text_Version__c = text.version;
        }
        insert caps;
        insert new Task(
            Subject = 'Call back Dr. Maria Bianchi',
            ActivityDate = Date.newInstance(2026, 11, 2),
            WhatId = caps[5].Id,
            OwnerId = UserInfo.getUserId(),
            Status = 'Not Started',
            Priority = 'Normal',
            Description = DEMO_NOTE
        );
    }

    /** Registrations per event: training meetings get fewer. */
    public static final Integer REGISTRATIONS_PER_EVENT = 50;
    public static final Integer REGISTRATIONS_PER_TRAINING = 20;
    public static final String TRAINING_TYPE = 'Training meeting';

    /** Surnames for registrants who are not in Salesforce: far from every mockup and volume surname, so they become new HCPs. */
    private static final List<String> NEW_REGISTRANT_SURNAMES = new List<String>{
        'Albertazzi', 'Cavallaro', 'Ercolani', 'Guerrieri', 'Lanfranchi', 'Nardecchia', 'Orlandini', 'Pacifici', 'Quadrelli', 'Ravaglia',
        'Santarelli', 'Tagliaferri', 'Ugolini', 'Valentinetti', 'Zampieri', 'Battistoni', 'Carbonetti', 'Donadoni', 'Gentilini', 'Mazzarella',
        'Pellicciari', 'Vescovini', 'Zanchetta', 'Brambati', 'Cerutti', 'Dalmasso', 'Ferraguti', 'Grasselli', 'Malaguti', 'Abbondanza',
        'Bergonzi', 'Calcagno', 'Dalpozzo', 'Fantozzi', 'Gherardini', 'Lodigiani', 'Mezzadri', 'Notarangelo', 'Pistoletto', 'Randazzo',
        'Scognamiglio', 'Tedeschini', 'Urbinati', 'Vianello', 'Zuccarini', 'Ambrosetti', 'Baldacci', 'Ciampolini', 'Desiderio', 'Facchinetti',
        'Innocenti', 'Loiacono', 'Nicoletti', 'Occhipinti', 'Raimondi', 'Sbarbaro', 'Toscanelli', 'Verzotti', 'Zoppetti', 'Arcangeli',
        'Bortolotti', 'Cocchiara', 'Durante', 'Evangelisti', 'Frigerio', 'Lattanzi', 'Pasquali', 'Righetti', 'Spadoni', 'Trevisan',
        'Zappalorto', 'Agostinelli', 'Bonvicini', 'Castellucci', 'Fumarola', 'Guidotti', 'Marangoni', 'Nobili', 'Petrucci', 'Rocchetti',
        'Tiraboschi', 'Varriale'
    };
    private static final List<String> NEW_REGISTRANT_FIRST_NAMES = new List<String>{
        'Alessia', 'Bruno', 'Carla', 'Daniele', 'Erica', 'Fabio', 'Gaia', 'Ivan', 'Lorena', 'Mirko', 'Noemi', 'Oscar', 'Paola', 'Renato'
    };
    private static final List<String> REGISTRANT_CITIES = new List<String>{
        'Milan', 'Rome', 'Turin', 'Bologna', 'Florence', 'Naples', 'Genoa', 'Verona', 'Padua', 'Bergamo', 'Bari', 'Palermo'
    };

    /**
     * Pre-event registrations for every event except the volume test event: 50 per congress, 20 per training meeting.
     * About 55% are existing HCPs registering with their own email (auto-matched), 10% existing HCPs with a personal
     * email and their registration number (matched by registration number), 35% people not in Salesforce (new HCPs);
     * about 40% tick the consent. Volume test HCPs are used as the existing ones (without volume data every registrant
     * is a new person). The congress also gets six named registrants for the demo script: Benedetti, Villa and Ferri
     * (consent on file, not ticked again: it stays), Esposito (consent at registration), Marchi and Galli (new).
     * Re-runnable: rows already imported are skipped.
     */
    public static EventRegistrationService.ImportResult registrations() {
        List<Event__c> events = [
            SELECT Id, Name, Event_Type__c
            FROM Event__c
            WHERE Name != :VolumeTestData.TEST_EVENT_NAME
            ORDER BY Start_Date__c ASC NULLS LAST, Name
            LIMIT 20
        ];
        if (events.isEmpty()) {
            throw new DemoException('No events: run ConsentDemoData.run() first.');
        }
        List<Contact> pool = registrantPool();
        List<String> specialties = ConsentCaptureConfig.specialties();
        EventRegistrationService.ImportResult total = new EventRegistrationService.ImportResult();
        Integer poolPos = 0;
        Integer newIdx = 0;
        for (Integer ei = 0; ei < events.size(); ei++) {
            Event__c ev = events[ei];
            Integer target = ev.Event_Type__c == TRAINING_TYPE ? REGISTRATIONS_PER_TRAINING : REGISTRATIONS_PER_EVENT;
            List<EventRegistrationService.Registrant> rows = new List<EventRegistrationService.Registrant>();
            Set<String> used = new Set<String>();
            if (ev.Name == CONGRESS_NAME) {
                rows.add(registrant('Laura', 'Benedetti', 'laura.benedetti@ospedale-example.it', 'Paediatrics', 'Padua', false));
                rows.add(registrant('Roberto', 'Esposito', 'roberto.esposito@aslroma-example.it', 'Paediatrics', 'Rome', true));
                rows.add(registrant('Andrea', 'Villa', 'andrea.villa@aovr-example.it', 'Paediatrics', 'Verona', false));
                rows.add(registrant('Federica', 'Marchi', 'federica.marchi@meyer-example.it', 'Paediatrics', 'Florence', true));
                rows.add(registrant('Tommaso', 'Galli', 'tommaso.galli@gmail.com', 'Neonatology', 'Milan', false));
                rows.add(registrant('Marco', 'Ferri', 'marco.ferri@policlinico-example.it', 'Paediatrics', 'Milan', false));
            }
            Integer guard = 0;
            while (rows.size() < target && guard < target * 3) {
                guard++;
                Integer slot = rows.size();
                Integer kind = Math.mod(slot, 20);
                Boolean consent = Math.mod(slot, 5) < 2;
                if (kind < 13 && !pool.isEmpty() && poolPos < pool.size()) {
                    Contact c = pool[poolPos];
                    poolPos++;
                    if (used.contains(c.Email.toLowerCase())) {
                        continue;
                    }
                    used.add(c.Email.toLowerCase());
                    Boolean byRegistration = kind >= 11 && String.isNotBlank(c.Registration_Number__c);
                    EventRegistrationService.Registrant r = registrant(
                        c.FirstName,
                        c.LastName,
                        byRegistration ? personalEmail(c.FirstName, c.LastName, 'reg') : c.Email,
                        c.Specialty__c,
                        c.MailingCity,
                        consent
                    );
                    if (byRegistration) {
                        r.registrationNumber = c.Registration_Number__c;
                    }
                    rows.add(r);
                } else if (newIdx < NEW_REGISTRANT_SURNAMES.size()) {
                    String last = NEW_REGISTRANT_SURNAMES[newIdx];
                    String first = NEW_REGISTRANT_FIRST_NAMES[Math.mod(newIdx, NEW_REGISTRANT_FIRST_NAMES.size())];
                    newIdx++;
                    rows.add(
                        registrant(
                            first,
                            last,
                            personalEmail(first, last, null),
                            specialties[Math.mod(newIdx, specialties.size())],
                            REGISTRANT_CITIES[Math.mod(newIdx + ei, REGISTRANT_CITIES.size())],
                            consent
                        )
                    );
                } else if (pool.isEmpty() || poolPos >= pool.size()) {
                    break;
                }
            }
            EventRegistrationService.ImportResult r = EventRegistrationService.register(ev.Id, rows);
            total.imported += r.imported;
            total.skipped += r.skipped;
            total.messages.add(ev.Name + ': ' + r.imported + ' imported, ' + r.skipped + ' skipped');
        }
        return total;
    }

    /** Volume test HCPs with a unique email and registration number, not part of a known duplicate pair. */
    private static List<Contact> registrantPool() {
        List<Contact> candidates = [
            SELECT Id, FirstName, LastName, Email, Specialty__c, MailingCity, Registration_Number__c, Test_Duplicate_Of__c
            FROM Contact
            WHERE Test_Data_Set__c = :VolumeTestData.DATA_SET AND Email != NULL AND FirstName != NULL
            ORDER BY OneKey_Id__c NULLS LAST, Id
            LIMIT 2000
        ];
        Map<String, Integer> emailCount = new Map<String, Integer>();
        Map<String, Integer> regCount = new Map<String, Integer>();
        Set<Id> inDuplicatePair = new Set<Id>();
        for (Contact c : candidates) {
            String e = c.Email.toLowerCase();
            emailCount.put(e, emailCount.containsKey(e) ? emailCount.get(e) + 1 : 1);
            String reg = HcpMatchEngine.registrationKey(c.Registration_Number__c);
            if (String.isNotBlank(reg)) {
                regCount.put(reg, regCount.containsKey(reg) ? regCount.get(reg) + 1 : 1);
            }
            if (c.Test_Duplicate_Of__c != null) {
                inDuplicatePair.add(c.Id);
                inDuplicatePair.add(c.Test_Duplicate_Of__c);
            }
        }
        List<Contact> pool = new List<Contact>();
        for (Contact c : candidates) {
            String reg = HcpMatchEngine.registrationKey(c.Registration_Number__c);
            Boolean uniqueReg = String.isBlank(reg) || regCount.get(reg) == 1;
            if (!inDuplicatePair.contains(c.Id) && emailCount.get(c.Email.toLowerCase()) == 1 && uniqueReg) {
                pool.add(c);
            }
        }
        return pool;
    }

    private static String personalEmail(String first, String last, String tag) {
        String local = HcpMatchEngine.normalizeName(first) + '.' + HcpMatchEngine.normalizeName(last);
        return local + (tag == null ? '' : '.' + tag) + '@gmail.com';
    }

    private static EventRegistrationService.Registrant registrant(String first, String last, String email, String spec, String city, Boolean consent) {
        EventRegistrationService.Registrant r = new EventRegistrationService.Registrant();
        r.firstName = first;
        r.lastName = last;
        r.email = email;
        r.specialty = spec;
        r.city = city;
        r.consent = consent;
        r.consentDate = '2026-09-20';
        return r;
    }

    private static Consent__c legacyConsent(Id contactId, Date d, String version, Boolean withdrawn) {
        Datetime at = Datetime.newInstance(d, Time.newInstance(10, 0, 0, 0));
        return new Consent__c(
            Contact__c = contactId,
            Consent_Type__c = CaptureConstants.CONSENT_TYPE_EMAIL,
            Status__c = withdrawn ? CaptureConstants.CONSENT_WITHDRAWN : CaptureConstants.CONSENT_CONFIRMED,
            Channel__c = CaptureConstants.CHANNEL_PITCHER,
            Captured_At__c = withdrawn ? at.addDays(-200) : at,
            Confirmed_At__c = withdrawn ? at.addDays(-200) : at,
            Withdrawn_At__c = withdrawn ? at : null,
            Consent_Text_Version__c = version,
            Opt_In_Method__c = CaptureConstants.METHOD_PITCHER,
            Matched_By__c = 'Pitcher',
            Gigya_Status__c = CaptureConstants.GIGYA_SENT,
            Gigya_Sent_At__c = at.addMinutes(5)
        );
    }

    private static Capture__c cap(
        Event__c ev,
        Integer day,
        String hm,
        String first,
        String last,
        String email,
        String spec,
        String city,
        String reg,
        String org,
        String channel,
        String rep,
        Boolean confirmed
    ) {
        List<String> parts = hm.split(':');
        Datetime at = Datetime.newInstance(Date.newInstance(2026, 10, day), Time.newInstance(Integer.valueOf(parts[0]), Integer.valueOf(parts[1]), 0, 0));
        return new Capture__c(
            Event__c = ev.Id,
            Captured_At__c = at,
            First_Name__c = first,
            Last_Name__c = last,
            Email__c = email,
            Specialty__c = spec,
            City__c = city,
            Registration_Number__c = reg,
            Organisation__c = org,
            Channel__c = channel,
            Captured_By_Name__c = rep,
            Consent_Given__c = true,
            Consent_Method__c = CaptureConstants.METHOD_EMAIL,
            Opt_In_Status__c = confirmed ? CaptureConstants.OPTIN_CONFIRMED : CaptureConstants.OPTIN_PENDING,
            Opt_In_Confirmed_At__c = confirmed ? at.addMinutes(3) : null,
            Send_Slides__c = true,
            Confirmation_Email_Status__c = CaptureConstants.EMAIL_NOT_REQUIRED,
            Processing_Stage__c = CaptureConstants.STAGE_RECEIVED,
            Matching_Status__c = CaptureConstants.MATCH_QUEUED
        );
    }

    // ------------------------------------------------------------ helpers for the demo

    /** Marks every queued consent as sent, standing in for the existing Gigya integration. */
    public static Integer simulateGigyaSync() {
        List<Consent__c> queued = [
            SELECT Id, Gigya_Status__c, Source_Capture__c
            FROM Consent__c
            WHERE Gigya_Status__c = :CaptureConstants.GIGYA_QUEUED
            LIMIT 5000
        ];
        if (!queued.isEmpty()) {
            ConsentRecordController.markSent(queued);
        }
        return queued.size();
    }

    /** Deletes the sample data created by run(). */
    public static void reset() {
        List<Event__c> events = [SELECT Id FROM Event__c WHERE Name IN (:CONGRESS_NAME, :TRAINING_NAME)];
        Set<Id> eventIds = new Map<Id, Event__c>(events).keySet();
        List<Capture__c> caps = [SELECT Id FROM Capture__c WHERE Event__c IN :eventIds];
        delete [SELECT Id FROM Task WHERE WhatId IN :caps];
        delete [SELECT Id FROM Consent__c WHERE Event__c IN :eventIds OR (Channel__c = :CaptureConstants.CHANNEL_PITCHER AND Contact__r.Test_Data_Set__c = NULL)];
        delete caps;
        delete events;
        List<Contact> demoContacts = [
            SELECT Id, AccountId
            FROM Contact
            WHERE (Email LIKE '%-example.it' OR Email LIKE '%@gmail.com') AND Test_Data_Set__c = NULL
        ];
        Set<Id> accountIds = new Set<Id>();
        for (Contact c : demoContacts) {
            accountIds.add(c.AccountId);
        }
        delete demoContacts;
        Set<String> hospitalNames = new Set<String>();
        for (List<String> h : MOCKUP_HOSPITALS) {
            hospitalNames.add(h[0]);
        }
        delete [
            SELECT Id
            FROM Account
            WHERE (Id IN :accountIds OR Parent.Name IN :hospitalNames) AND Test_Data_Set__c = NULL AND Id NOT IN (SELECT AccountId FROM Contact)
        ];
        // Hospitals last; one that still has departments with other HCPs is kept.
        Database.delete([SELECT Id FROM Account WHERE Name IN :hospitalNames AND Id NOT IN (SELECT AccountId FROM Contact)], false);
    }
}
