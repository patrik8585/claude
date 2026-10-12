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
        ConsentCaptureConfig.cached = null;
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

        Map<String, Account> accounts = new Map<String, Account>();
        for (List<Object> h : hcps) {
            String org = (String) h[6];
            if (!accounts.containsKey(org)) {
                Account a = new Account(Name = org);
                a.setOptions(dml);
                accounts.put(org, a);
            }
        }
        insert accounts.values();

        Map<String, Contact> contacts = new Map<String, Contact>();
        for (List<Object> h : hcps) {
            Contact c = new Contact(
                FirstName = (String) h[1],
                LastName = (String) h[2],
                Email = (String) h[3],
                Specialty__c = (String) h[4],
                MailingCity = (String) h[5],
                AccountId = accounts.get((String) h[6]).Id,
                Registration_Number__c = (String) h[7],
                OneKey_Id__c = (String) h[8],
                Territory__c = ((Boolean) h[9]) ? TERRITORY_REP : TERRITORY_OTHER,
                Consent_Status__c = CaptureConstants.HCP_NONE
            );
            c.setOptions(dml);
            contacts.put((String) h[0], c);
        }
        insert contacts.values();

        // Existing consents (as created by Pitcher today) and one opt-out.
        List<Consent__c> legacy = new List<Consent__c>{
            legacyConsent(contacts.get('H1').Id, Date.newInstance(2025, 3, 12), 'v3.1', false),
            legacyConsent(contacts.get('H2').Id, Date.newInstance(2025, 9, 2), 'v3.1', false),
            legacyConsent(contacts.get('H14').Id, Date.newInstance(2026, 1, 21), 'v3.2', false),
            legacyConsent(contacts.get('H3').Id, Date.newInstance(2025, 6, 8), 'v3.1', true)
        };
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
        delete [SELECT Id FROM Consent__c WHERE Event__c IN :eventIds OR Channel__c = :CaptureConstants.CHANNEL_PITCHER];
        delete caps;
        delete events;
        List<Contact> demoContacts = [
            SELECT Id, AccountId
            FROM Contact
            WHERE Email LIKE '%-example.it' OR Email LIKE '%@gmail.com'
        ];
        Set<Id> accountIds = new Set<Id>();
        for (Contact c : demoContacts) {
            accountIds.add(c.AccountId);
        }
        delete demoContacts;
        delete [SELECT Id FROM Account WHERE Id IN :accountIds AND Id NOT IN (SELECT AccountId FROM Contact)];
    }
}
