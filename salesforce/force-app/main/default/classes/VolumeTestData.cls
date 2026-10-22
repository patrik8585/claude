/**
 * TEST ONLY - realistic volume data to measure matching accuracy (Matching › Accuracy, test set).
 *
 *   VolumeTestData.generate();            // DEV size (fits the 5 MB of a Developer Edition):
 *                                         //   cleanup + 10 hospitals, ~55 departments, ~260 HCPs, 59 test captures
 *   VolumeTestData.generate('FULL');      // sandbox size: 30 hospitals, ~170 departments, ~1,000 HCPs, 150 test captures (~7 MB)
 *   VolumeTestData.regenerateCaptures();  // only the test captures (e.g. after changing Matching_Setting__mdt)
 *   VolumeTestData.cleanup();             // deletes everything the generator created
 *
 * Runs as Batch Apex, one step per execute() (fresh governor limits per step). The data set is
 * deterministic (fixed seed), so every run produces the same people and the same hard cases:
 * namesakes, typos, accents (Nicolò/Nicolo), swapped first/last names, personal vs institutional
 * emails, missing registration numbers, HCPs in 2 departments and real duplicates (same person twice,
 * marked with Contact.Test_Duplicate_Of__c). Each test capture carries Expected_Outcome__c /
 * Expected_Contact__c / Test_Case__c; the Matching Accuracy tab compares them with the engine's result.
 *
 * Records are tagged with Test_Data_Set__c: VOLUME (hospitals, departments, HCPs) and VOLUME-CAPTURES
 * (test captures and the HCPs created from them). The 14 mockup HCPs and the 2 mockup events are never touched.
 */
public without sharing class VolumeTestData implements Database.Batchable<String> {
    public static final String DATA_SET = 'VOLUME';
    public static final String CAPTURE_SET = 'VOLUME-CAPTURES';
    public static final String TEST_EVENT_NAME = 'Matching accuracy test set (synthetic)';
    public static final Integer HCP_CHUNK = 300;
    public static final Long SEED = 20261015;

    public static final String OUT_AUTO = 'Auto-match';
    public static final String OUT_REVIEW = 'Review';
    public static final String OUT_NEW = 'New HCP';

    /** Developer Edition size: about 2 MB of data storage (each record counts about 2 KB). */
    public static final String SIZE_DEV = 'DEV';
    /** Full size, about 7 MB: needs a sandbox or an org with more than 5 MB of data storage. */
    public static final String SIZE_FULL = 'FULL';

    private List<String> steps;
    /** Kept on the batch instance: static variables do not survive between execute() calls. */
    private String runSize = SIZE_DEV;

    /** Test hook: a much smaller data set (6 hospitals, 1 capture per test case) so unit tests stay within limits. */
    public static Boolean small = false;
    /** Data set size used by Plan: SIZE_DEV or SIZE_FULL (ignored when small = true). */
    public static String size = SIZE_DEV;

    public VolumeTestData(List<String> steps) {
        this.steps = steps;
    }

    public VolumeTestData(List<String> steps, String runSize) {
        this.steps = steps;
        this.runSize = runSize == SIZE_FULL ? SIZE_FULL : SIZE_DEV;
    }

    // ------------------------------------------------------------ public API

    public static Id generate() {
        return generate(SIZE_DEV);
    }

    public static Id generate(String requestedSize) {
        size = requestedSize == SIZE_FULL ? SIZE_FULL : SIZE_DEV;
        Plan p = new Plan();
        List<String> s = new List<String>{ 'CLEAN_CAPTURES', 'CLEAN_CONTACTS', 'CLEAN_ACCOUNTS', 'HOSPITALS' };
        Integer chunks = (p.hcps.size() + HCP_CHUNK - 1) / HCP_CHUNK;
        for (Integer i = 0; i < chunks; i++) {
            s.add('HCPS:' + i);
        }
        s.add('DUPLICATES');
        s.add('CAPTURES');
        return Database.executeBatch(new VolumeTestData(s, size), 1);
    }

    /** Recreates the test captures for the data set in the org (its size is detected from the hospital count). */
    public static Id regenerateCaptures() {
        Integer hospitalCount = [SELECT COUNT() FROM Account WHERE Test_Data_Set__c = :DATA_SET AND ParentId = NULL];
        String detected = hospitalCount > 10 ? SIZE_FULL : SIZE_DEV;
        return Database.executeBatch(new VolumeTestData(new List<String>{ 'CLEAN_CAPTURES', 'CAPTURES' }, detected), 1);
    }

    public static Id cleanup() {
        return Database.executeBatch(new VolumeTestData(new List<String>{ 'CLEAN_CAPTURES', 'CLEAN_CONTACTS', 'CLEAN_ACCOUNTS' }), 1);
    }

    // ------------------------------------------------------------ batch

    public Iterable<String> start(Database.BatchableContext bc) {
        return steps;
    }

    public void execute(Database.BatchableContext bc, List<String> scope) {
        size = runSize;
        for (String step : scope) {
            runStep(step);
        }
    }

    public void finish(Database.BatchableContext bc) {
        System.debug(LoggingLevel.INFO, 'VolumeTestData finished: ' + String.join(steps, ', '));
    }

    @TestVisible
    private static void runStep(String step) {
        if (step == 'CLEAN_CAPTURES') {
            cleanCaptures();
        } else if (step == 'CLEAN_CONTACTS') {
            cleanContacts();
        } else if (step == 'CLEAN_ACCOUNTS') {
            cleanAccounts();
        } else if (step == 'HOSPITALS') {
            insertHospitals(new Plan());
        } else if (step.startsWith('HCPS:')) {
            insertHcps(new Plan(), Integer.valueOf(step.substringAfter(':')));
        } else if (step == 'DUPLICATES') {
            insertDuplicates(new Plan());
        } else if (step == 'CAPTURES') {
            insertCaptures(new Plan());
        }
    }

    // ------------------------------------------------------------ cleanup

    private static void cleanCaptures() {
        List<Capture__c> caps = [SELECT Id, Matched_Contact__c FROM Capture__c WHERE Test_Data_Set__c = :CAPTURE_SET LIMIT 5000];
        Set<Id> touched = new Set<Id>();
        for (Capture__c c : caps) {
            if (c.Matched_Contact__c != null) {
                touched.add(c.Matched_Contact__c);
            }
        }
        delete [SELECT Id FROM Consent__c WHERE Source_Capture__c IN :caps];
        delete [SELECT Id FROM Task WHERE WhatId IN :caps];
        delete caps;
        purge(caps);
        // HCPs created from test captures
        List<Contact> created = [SELECT Id FROM Contact WHERE Test_Data_Set__c = :CAPTURE_SET LIMIT 5000];
        delete created;
        purge(created);
        delete [SELECT Id FROM Event__c WHERE Name = :TEST_EVENT_NAME];
        touched.removeAll(new Map<Id, Contact>(created).keySet());
        ConsentService.refreshContactSummary(touched);
    }

    private static void cleanContacts() {
        List<Contact> contacts = [SELECT Id FROM Contact WHERE Test_Data_Set__c = :DATA_SET LIMIT 5000];
        Set<Id> ids = new Map<Id, Contact>(contacts).keySet();
        delete [SELECT Id FROM Consent__c WHERE Contact__c IN :ids];
        delete contacts;
        purge(contacts);
    }

    /** Empties the deleted test records from the Recycle Bin so the storage is freed at once. Never throws. */
    private static void purge(List<SObject> deleted) {
        if (deleted.isEmpty()) {
            return;
        }
        try {
            Database.emptyRecycleBin(deleted);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Recycle Bin not emptied: ' + e.getMessage());
        }
    }

    private static void cleanAccounts() {
        List<Account> departments = [
            SELECT Id
            FROM Account
            WHERE Test_Data_Set__c = :DATA_SET AND ParentId != NULL AND Id NOT IN (SELECT AccountId FROM Contact)
            LIMIT 5000
        ];
        delete departments;
        purge(departments);
        List<Account> rest = [SELECT Id FROM Account WHERE Test_Data_Set__c = :DATA_SET AND Id NOT IN (SELECT AccountId FROM Contact) LIMIT 5000];
        List<Account> deleted = new List<Account>();
        List<Database.DeleteResult> results = Database.delete(rest, false);
        for (Integer i = 0; i < results.size(); i++) {
            if (results[i].isSuccess()) {
                deleted.add(rest[i]);
            }
        }
        purge(deleted);
        HcoDirectory.reset();
    }

    // ------------------------------------------------------------ inserts

    private static void insertHospitals(Plan p) {
        Database.DMLOptions dml = CaptureResolutionService.allowDuplicates();
        Id rtH = HcoDirectory.recordTypeId(HcoDirectory.RT_HOSPITAL);
        Id rtD = HcoDirectory.recordTypeId(HcoDirectory.RT_DEPARTMENT);
        List<Account> hospitals = new List<Account>();
        for (HospitalSpec h : p.hospitals) {
            Account a = new Account(
                Name = h.name,
                BillingCity = h.city,
                Email_Domain__c = h.domain,
                Aliases__c = h.aliases,
                OneKey_Workplace_Id__c = h.key,
                RecordTypeId = rtH,
                Test_Data_Set__c = DATA_SET
            );
            a.setOptions(dml);
            hospitals.add(a);
        }
        Database.insert(hospitals, dml);
        List<Account> depts = new List<Account>();
        for (Integer i = 0; i < p.hospitals.size(); i++) {
            HospitalSpec h = p.hospitals[i];
            for (Integer j = 0; j < h.departments.size(); j++) {
                Account d = new Account(
                    Name = h.departments[j] + ' - ' + h.name,
                    ParentId = hospitals[i].Id,
                    BillingCity = h.city,
                    Department_Type__c = h.departments[j],
                    OneKey_Workplace_Id__c = h.key + '-D' + j,
                    RecordTypeId = rtD,
                    Test_Data_Set__c = DATA_SET
                );
                d.setOptions(dml);
                depts.add(d);
            }
        }
        Database.insert(depts, dml);
        HcoDirectory.reset();
    }

    private static Map<String, Id> accountsByKey() {
        Map<String, Id> m = new Map<String, Id>();
        for (Account a : [SELECT Id, OneKey_Workplace_Id__c FROM Account WHERE Test_Data_Set__c = :DATA_SET AND OneKey_Workplace_Id__c != NULL LIMIT 5000]) {
            m.put(a.OneKey_Workplace_Id__c.toUpperCase(), a.Id);
        }
        return m;
    }

    private static void insertHcps(Plan p, Integer chunk) {
        Map<String, Id> hco = accountsByKey();
        Integer fromIdx = chunk * HCP_CHUNK;
        Integer toIdx = Math.min(p.hcps.size(), fromIdx + HCP_CHUNK);
        List<HcpSpec> specs = new List<HcpSpec>();
        for (Integer i = fromIdx; i < toIdx; i++) {
            specs.add(p.hcps[i]);
        }
        insertContacts(p, specs, hco, new Map<Integer, Id>());
    }

    private static void insertDuplicates(Plan p) {
        Map<String, Id> hco = accountsByKey();
        Set<String> keys = new Set<String>();
        for (HcpSpec d : p.duplicates) {
            keys.add(p.hcps[d.dupOf].oneKey);
        }
        Map<String, Id> byOneKey = new Map<String, Id>();
        for (Contact c : [SELECT Id, OneKey_Id__c FROM Contact WHERE OneKey_Id__c IN :keys AND Test_Data_Set__c = :DATA_SET]) {
            byOneKey.put(c.OneKey_Id__c, c.Id);
        }
        Map<Integer, Id> originals = new Map<Integer, Id>();
        for (HcpSpec d : p.duplicates) {
            originals.put(d.dupOf, byOneKey.get(p.hcps[d.dupOf].oneKey));
        }
        insertContacts(p, p.duplicates, hco, originals);
    }

    private static void insertContacts(Plan p, List<HcpSpec> specs, Map<String, Id> hco, Map<Integer, Id> originals) {
        Database.DMLOptions dml = CaptureResolutionService.allowDuplicates();
        List<Contact> contacts = new List<Contact>();
        for (HcpSpec s : specs) {
            Contact c = new Contact(
                FirstName = s.first,
                LastName = s.last,
                Email = s.email,
                Specialty__c = s.specialty,
                MailingCity = s.city,
                Registration_Number__c = s.reg,
                OneKey_Id__c = s.oneKey,
                Territory__c = s.territory,
                AccountId = hco.get(p.deptKey(s.hospital, s.dept).toUpperCase()),
                Consent_Status__c = CaptureConstants.HCP_NONE,
                Test_Data_Set__c = DATA_SET,
                Test_Duplicate_Of__c = s.dupOf >= 0 ? originals.get(s.dupOf) : null
            );
            c.setOptions(dml);
            contacts.add(c);
        }
        Database.insert(contacts, dml);
        List<HCP_Affiliation__c> aff = new List<HCP_Affiliation__c>();
        for (Integer i = 0; i < specs.size(); i++) {
            HcpSpec s = specs[i];
            aff.add(
                new HCP_Affiliation__c(
                    Contact__c = contacts[i].Id,
                    HCO__c = contacts[i].AccountId,
                    Primary__c = true,
                    Role__c = s.role,
                    Start_Date__c = Date.newInstance(2015 + Math.mod(s.idx, 10), 1 + Math.mod(s.idx, 12), 1)
                )
            );
            if (s.secondHospital >= 0) {
                aff.add(
                    new HCP_Affiliation__c(
                        Contact__c = contacts[i].Id,
                        HCO__c = hco.get(p.deptKey(s.secondHospital, s.secondDept).toUpperCase()),
                        Primary__c = false,
                        Role__c = 'Consultant',
                        Start_Date__c = Date.newInstance(2022, 3, 1)
                    )
                );
            }
        }
        insert aff;
    }

    private static void insertCaptures(Plan p) {
        List<Event__c> evs = [SELECT Id FROM Event__c WHERE Name = :TEST_EVENT_NAME LIMIT 1];
        Event__c ev;
        if (evs.isEmpty()) {
            ev = new Event__c(
                Name = TEST_EVENT_NAME,
                Short_Name__c = 'Accuracy test set',
                Event_Type__c = 'Congress',
                Start_Date__c = Date.newInstance(2026, 10, 15),
                End_Date__c = Date.newInstance(2026, 10, 15),
                Location__c = 'Synthetic data',
                Active__c = false,
                Public_Capture_Enabled__c = false
            );
            insert ev;
        } else {
            ev = evs[0];
        }
        Set<String> keys = new Set<String>();
        for (CaptureSpec cs : p.captures) {
            if (cs.expected >= 0) {
                keys.add(p.hcps[cs.expected].oneKey);
            }
        }
        Map<String, Id> byOneKey = new Map<String, Id>();
        for (Contact c : [SELECT Id, OneKey_Id__c FROM Contact WHERE OneKey_Id__c IN :keys AND Test_Data_Set__c = :DATA_SET]) {
            byOneKey.put(c.OneKey_Id__c, c.Id);
        }
        String version = ConsentCaptureConfig.activeConsentText().version;
        List<String> channels = new List<String>{ CaptureConstants.CHANNEL_SELF, CaptureConstants.CHANNEL_KIOSK, CaptureConstants.CHANNEL_REP };
        List<String> reps = new List<String>{ 'Anna Colombo', 'Davide Ricci', 'Sara Fontana' };
        List<Capture__c> rows = new List<Capture__c>();
        Datetime t0 = Datetime.newInstance(2026, 10, 15, 9, 0, 0);
        for (Integer i = 0; i < p.captures.size(); i++) {
            CaptureSpec cs = p.captures[i];
            String channel = channels[Math.mod(i, 3)];
            rows.add(
                new Capture__c(
                    Event__c = ev.Id,
                    Captured_At__c = t0.addMinutes(i * 3),
                    First_Name__c = cs.first,
                    Last_Name__c = cs.last,
                    Email__c = cs.email,
                    Specialty__c = cs.specialty,
                    City__c = cs.city,
                    Organisation__c = cs.organisation,
                    Registration_Number__c = cs.reg,
                    Channel__c = channel,
                    Captured_By_Name__c = channel == CaptureConstants.CHANNEL_REP ? reps[Math.mod(i, 3)] : null,
                    Consent_Given__c = true,
                    Consent_Method__c = CaptureConstants.METHOD_EMAIL,
                    Opt_In_Status__c = CaptureConstants.OPTIN_PENDING,
                    Consent_Text_Version__c = version,
                    Send_Slides__c = true,
                    Confirmation_Email_Status__c = CaptureConstants.EMAIL_NOT_REQUIRED,
                    Processing_Stage__c = CaptureConstants.STAGE_RECEIVED,
                    Matching_Status__c = CaptureConstants.MATCH_QUEUED,
                    Test_Data_Set__c = CAPTURE_SET,
                    Test_Case__c = cs.testCase,
                    Expected_Outcome__c = cs.outcome,
                    Expected_Contact__c = cs.expected >= 0 ? byOneKey.get(p.hcps[cs.expected].oneKey) : null
                )
            );
        }
        insert rows;
    }

    // ------------------------------------------------------------ deterministic plan

    public class HospitalSpec {
        public String name;
        public String city;
        public String province;
        public String domain;
        public String aliases;
        public String key;
        public List<String> departments = new List<String>();
    }

    public class HcpSpec {
        public Integer idx;
        public String first;
        public String last;
        public String email;
        public String reg;
        public String oneKey;
        public String specialty;
        public String city;
        public String territory;
        public String role;
        public Integer hospital;
        public Integer dept;
        public Integer secondHospital = -1;
        public Integer secondDept = -1;
        /** Index of the original in Plan.hcps for a deliberate duplicate. */
        public Integer dupOf = -1;
        public String dupKind;
        public Boolean namesake = false;
        public Boolean institutionalEmail = false;
    }

    public class CaptureSpec {
        public String testCase;
        public String outcome;
        /** Index in Plan.hcps of the real HCP, -1 = really a new HCP. */
        public Integer expected = -1;
        public String first;
        public String last;
        public String email;
        public String reg;
        public String specialty;
        public String city;
        public String organisation;
    }

    public class Plan {
        public List<HospitalSpec> hospitals = new List<HospitalSpec>();
        public List<HcpSpec> hcps = new List<HcpSpec>();
        public List<HcpSpec> duplicates = new List<HcpSpec>();
        public List<CaptureSpec> captures = new List<CaptureSpec>();
        private Long state = VolumeTestData.SEED;
        private Boolean small = VolumeTestData.small;
        /** Developer Edition size (see SIZE_DEV). */
        private Boolean dev = !VolumeTestData.small && VolumeTestData.size != VolumeTestData.SIZE_FULL;
        private Set<String> usedEmails = new Set<String>();
        private Set<String> usedNames = new Set<String>();
        private Integer emailSeq = 0;

        public Plan() {
            buildHospitals();
            buildHcps();
            buildNamesakes();
            buildSecondAffiliations();
            buildDuplicates();
            buildCaptures();
        }

        public Integer rnd(Integer n) {
            state = Math.mod(state * 1103515245L + 12345L, 2147483648L);
            return Math.mod(state / 65536L, (Long) n).intValue();
        }

        public String pick(List<String> values) {
            return values[rnd(values.size())];
        }

        public String deptKey(Integer hospital, Integer dept) {
            return hospitals[hospital].key + '-D' + dept;
        }

        private void buildHospitals() {
            List<Integer> picked = new List<Integer>();
            for (Integer i = 0; i < VolumeTestData.HOSPITALS.size(); i++) {
                // DEV: every third hospital (10, spread across Italy); small: the first 6
                if ((small && i < 6) || (dev && Math.mod(i, 3) == 0) || (!small && !dev)) {
                    picked.add(i);
                }
            }
            for (Integer i : picked) {
                List<String> row = VolumeTestData.HOSPITALS[i];
                HospitalSpec h = new HospitalSpec();
                h.name = row[0];
                h.city = row[1];
                h.province = row[2];
                h.domain = row[3];
                h.aliases = row[4];
                h.key = 'VOLH' + String.valueOf(i + 1).leftPad(2, '0');
                h.departments.add('Paediatrics');
                Integer count = 3 + rnd(6);
                Integer offset = rnd(VolumeTestData.DEPARTMENT_TYPES.size());
                for (Integer k = 0; h.departments.size() < count && k < VolumeTestData.DEPARTMENT_TYPES.size(); k++) {
                    String t = VolumeTestData.DEPARTMENT_TYPES[Math.mod(offset + k, VolumeTestData.DEPARTMENT_TYPES.size())];
                    if (!h.departments.contains(t)) {
                        h.departments.add(t);
                    }
                }
                hospitals.add(h);
            }
        }

        private void buildHcps() {
            for (Integer hi = 0; hi < hospitals.size(); hi++) {
                HospitalSpec h = hospitals[hi];
                for (Integer di = 0; di < h.departments.size(); di++) {
                    Integer n = small ? 2 : (dev ? 3 + rnd(4) : 4 + rnd(5));
                    for (Integer k = 0; k < n; k++) {
                        HcpSpec s = newHcp(hi, di);
                        String first;
                        String last;
                        Integer tries = 0;
                        do {
                            first = rnd(2) == 0 ? pick(VolumeTestData.MALE) : pick(VolumeTestData.FEMALE);
                            last = pick(VolumeTestData.SURNAMES);
                            tries++;
                        } while (usedNames.contains(nameKey(first, last)) && tries < 20);
                        s.first = first;
                        s.last = last;
                        usedNames.add(nameKey(first, last));
                        assignContactData(s, true);
                        hcps.add(s);
                    }
                }
            }
        }

        private HcpSpec newHcp(Integer hi, Integer di) {
            HcpSpec s = new HcpSpec();
            s.idx = hcps.size();
            s.hospital = hi;
            s.dept = di;
            s.specialty = HcoDirectory.SPECIALTY_BY_DEPARTMENT.get(hospitals[hi].departments[di]);
            s.city = hospitals[hi].city;
            s.territory = Math.mod(hi, 3) == 0 ? ConsentDemoData.TERRITORY_REP : ConsentDemoData.TERRITORY_OTHER;
            s.role = pick(VolumeTestData.ROLES);
            s.oneKey = 'WITAV' + String.valueOf(s.idx + 1).leftPad(7, '0');
            return s;
        }

        /** Email (65% institutional, 20% personal, 15% none) and registration number (85%). */
        private void assignContactData(HcpSpec s, Boolean allowMissing) {
            Integer e = rnd(100);
            if (e < 65) {
                s.email = institutionalEmail(s.first, s.last, hospitals[s.hospital].domain, rnd(3));
                s.institutionalEmail = true;
            } else if (e < 85 || !allowMissing) {
                s.email = personalEmail(s.first, s.last);
            }
            if (rnd(100) < 85 || !allowMissing) {
                s.reg = hospitals[s.hospital].province + '-' + String.valueOf(10000 + Math.mod((s.idx + 1) * 7919, 89999));
            }
        }

        private void buildNamesakes() {
            Integer originals = hcps.size();
            for (Integer k = 0; k < (small ? 4 : (dev ? 10 : 25)); k++) {
                HcpSpec src = hcps[rnd(originals)];
                Integer hi = rnd(hospitals.size());
                if (hospitals[hi].city == hospitals[src.hospital].city) {
                    hi = Math.mod(hi + 7, hospitals.size());
                }
                HcpSpec s = newHcp(hi, rnd(hospitals[hi].departments.size()));
                s.first = src.first;
                s.last = src.last;
                s.namesake = true;
                assignContactData(s, true);
                hcps.add(s);
                src.namesake = true;
            }
        }

        /** About 10% of HCPs also work in a second department (same hospital, sometimes another one). */
        private void buildSecondAffiliations() {
            for (HcpSpec s : hcps) {
                if (rnd(10) != 0) {
                    continue;
                }
                Integer hi = rnd(4) == 0 ? rnd(hospitals.size()) : s.hospital;
                Integer di = rnd(hospitals[hi].departments.size());
                if (hi == s.hospital && di == s.dept) {
                    di = Math.mod(di + 1, hospitals[hi].departments.size());
                }
                if (hi != s.hospital || di != s.dept) {
                    s.secondHospital = hi;
                    s.secondDept = di;
                }
            }
        }

        /** Real duplicates (30, DEV 15): the same person entered a second time, in 5 different ways. */
        private void buildDuplicates() {
            List<String> kinds = new List<String>();
            addTimes(kinds, 'same-email', small ? 1 : (dev ? 3 : 8));
            addTimes(kinds, 'personal-email-same-reg', small ? 1 : (dev ? 3 : 8));
            addTimes(kinds, 'swapped-names', small ? 1 : (dev ? 3 : 5));
            addTimes(kinds, 'typo-surname', small ? 1 : (dev ? 3 : 5));
            addTimes(kinds, 'moved-hospital', small ? 1 : (dev ? 3 : 4));
            Set<Integer> used = new Set<Integer>();
            for (String kind : kinds) {
                HcpSpec src;
                Integer tries = 0;
                do {
                    src = hcps[rnd(hcps.size())];
                    tries++;
                } while ((used.contains(src.idx) || src.namesake || !src.institutionalEmail || src.reg == null) && tries < 200);
                used.add(src.idx);
                src.dupKind = kind;
                HcpSpec d = new HcpSpec();
                d.idx = 100000 + duplicates.size();
                d.dupOf = src.idx;
                d.dupKind = kind;
                d.hospital = src.hospital;
                d.dept = src.dept;
                d.specialty = src.specialty;
                d.city = src.city;
                d.territory = src.territory;
                d.role = src.role;
                d.first = src.first;
                d.last = src.last;
                if (kind == 'same-email') {
                    d.first = VolumeTestData.stripAccents(src.first);
                    d.email = src.email;
                } else if (kind == 'personal-email-same-reg') {
                    d.email = personalEmail(src.first, src.last);
                    d.reg = src.reg.replace('-', ' ');
                } else if (kind == 'swapped-names') {
                    d.first = src.last;
                    d.last = src.first;
                } else if (kind == 'typo-surname') {
                    d.last = VolumeTestData.typo(src.last);
                    d.email = personalEmail(src.first, src.last);
                } else {
                    Integer hi = Math.mod(src.hospital + 1 + rnd(hospitals.size() - 1), hospitals.size());
                    d.hospital = hi;
                    d.dept = 0;
                    d.specialty = 'Paediatrics';
                    d.city = hospitals[hi].city;
                    d.email = institutionalEmail(src.first, src.last, hospitals[hi].domain, 0);
                    d.reg = src.reg;
                }
                duplicates.add(d);
            }
        }

        // -------------------------------------------------------- captures

        private void buildCaptures() {
            Set<Integer> usedSrc = new Set<Integer>();
            addCases('Exact institutional email', VolumeTestData.OUT_AUTO, 20, usedSrc);
            addCases('Registration number, other format', VolumeTestData.OUT_AUTO, 15, usedSrc);
            addCases('Personal email, same hospital', VolumeTestData.OUT_REVIEW, 15, usedSrc);
            addCases('Typo in surname', VolumeTestData.OUT_REVIEW, 10, usedSrc);
            addCases('Accent / apostrophe variant', VolumeTestData.OUT_REVIEW, 8, usedSrc);
            addCases('Swapped first and last name', VolumeTestData.OUT_REVIEW, 8, usedSrc);
            addCases('Namesake', VolumeTestData.OUT_REVIEW, 10, usedSrc);
            addCases('Really new HCP', VolumeTestData.OUT_NEW, 25, usedSrc);
            addCases('New HCP, existing surname', VolumeTestData.OUT_REVIEW, 10, usedSrc);
            addCases('Email of a duplicate record', VolumeTestData.OUT_AUTO, 6, usedSrc);
            addCases('Email shared by duplicates', VolumeTestData.OUT_REVIEW, 6, usedSrc);
            addCases('New address, same institution', VolumeTestData.OUT_REVIEW, 7, usedSrc);
            addCases('Email and registration conflict', VolumeTestData.OUT_REVIEW, 5, usedSrc);
            addCases('Typo in surname, no hospital', VolumeTestData.OUT_REVIEW, 5, usedSrc);
        }

        private void addCases(String testCase, String outcome, Integer count, Set<Integer> usedSrc) {
            if (small) {
                count = 1;
            } else if (dev) {
                // about 40% of the full set: 59 captures instead of 150
                count = Math.max(2, (count * 2 + 2) / 5);
            }
            for (Integer k = 0; k < count; k++) {
                CaptureSpec c = new CaptureSpec();
                c.testCase = testCase;
                c.outcome = outcome;
                if (testCase == 'Really new HCP') {
                    c.first = rnd(2) == 0 ? pick(VolumeTestData.MALE) : pick(VolumeTestData.FEMALE);
                    c.last = VolumeTestData.NEW_SURNAMES[Math.mod(k, VolumeTestData.NEW_SURNAMES.size())];
                    Integer hi = rnd(hospitals.size());
                    c.specialty = HcoDirectory.SPECIALTY_BY_DEPARTMENT.get(pick(hospitals[hi].departments));
                    c.city = hospitals[hi].city;
                    // a third use their institutional address: the hospital is found, the HCP is still new
                    c.email = Math.mod(k, 3) == 0 ? institutionalEmail(c.first, c.last, hospitals[hi].domain, 0) : personalEmail(c.first, c.last);
                    captures.add(c);
                    continue;
                }
                if (testCase == 'New HCP, existing surname') {
                    HcpSpec other = hcps[rnd(hcps.size())];
                    String first;
                    Integer tries = 0;
                    do {
                        first = rnd(2) == 0 ? pick(VolumeTestData.MALE) : pick(VolumeTestData.FEMALE);
                        tries++;
                    } while ((usedNames.contains(nameKey(first, other.last)) || similarToAnyFirst(first, other.last)) && tries < 30);
                    c.first = first;
                    c.last = other.last;
                    Integer hi = rnd(hospitals.size());
                    c.specialty = other.specialty;
                    c.city = hospitals[hi].city;
                    c.email = personalEmail(c.first, c.last);
                    captures.add(c);
                    continue;
                }
                HcpSpec src = pickSource(testCase, usedSrc);
                c.expected = src.dupOf >= 0 ? src.dupOf : src.idx;
                HcpSpec real = hcps[c.expected];
                HospitalSpec h = hospitals[real.hospital];
                c.first = real.first;
                c.last = real.last;
                c.specialty = real.specialty;
                c.city = real.city;
                if (testCase == 'Exact institutional email') {
                    c.email = real.email;
                } else if (testCase == 'Registration number, other format') {
                    c.email = personalEmail(real.first, real.last);
                    c.reg = regVariant(real.reg, k);
                } else if (testCase == 'Personal email, same hospital') {
                    c.email = personalEmail(real.first, real.last);
                    c.organisation = Math.mod(k, 2) == 0 ? h.name : h.aliases.substringBefore(';').trim();
                } else if (testCase == 'Typo in surname') {
                    c.last = VolumeTestData.typo(real.last);
                    c.email = personalEmail(real.first, real.last);
                    c.organisation = h.name;
                } else if (testCase == 'Accent / apostrophe variant') {
                    c.first = VolumeTestData.stripAccents(real.first);
                    c.last = VolumeTestData.stripAccents(real.last).replace('\'', ' ');
                    c.organisation = h.aliases.substringBefore(';').trim();
                } else if (testCase == 'Swapped first and last name') {
                    c.first = real.last;
                    c.last = real.first;
                    c.organisation = h.name;
                } else if (testCase == 'Namesake') {
                    c.email = personalEmail(real.first, real.last);
                } else if (testCase == 'Email of a duplicate record') {
                    c.email = src.email;
                } else if (testCase == 'Email shared by duplicates') {
                    c.email = src.email;
                } else if (testCase == 'New address, same institution') {
                    c.email = institutionalEmail(real.first, real.last, h.domain, 3);
                } else if (testCase == 'Email and registration conflict') {
                    c.email = real.email;
                    HcpSpec other = hcps[Math.mod(real.idx + 17, hcps.size())];
                    c.reg = other.reg == null || other.reg == real.reg ? h.province + '-99999' : other.reg;
                } else if (testCase == 'Typo in surname, no hospital') {
                    c.last = VolumeTestData.typo(real.last);
                    c.email = personalEmail(real.first, real.last);
                }
                captures.add(c);
            }
        }

        private HcpSpec pickSource(String testCase, Set<Integer> usedSrc) {
            if (testCase == 'Email of a duplicate record' || testCase == 'Email shared by duplicates') {
                String kind = testCase == 'Email of a duplicate record' ? 'personal-email-same-reg' : 'same-email';
                for (HcpSpec d : duplicates) {
                    if (d.dupKind == kind && !usedSrc.contains(-d.idx)) {
                        usedSrc.add(-d.idx);
                        return d;
                    }
                }
            }
            for (Integer tries = 0; tries < 500; tries++) {
                HcpSpec s = hcps[rnd(hcps.size())];
                if (usedSrc.contains(s.idx) || !fits(testCase, s)) {
                    continue;
                }
                usedSrc.add(s.idx);
                return s;
            }
            return hcps[rnd(hcps.size())];
        }

        /** Keeps each test case unambiguous: e.g. an "exact email" source has no duplicate sharing that email. */
        private Boolean fits(String testCase, HcpSpec s) {
            Boolean plain = s.dupKind == null && !s.namesake;
            if (testCase == 'Exact institutional email' || testCase == 'New address, same institution') {
                return plain && s.institutionalEmail;
            }
            if (testCase == 'Email and registration conflict') {
                return plain && s.institutionalEmail && s.reg != null;
            }
            if (testCase == 'Registration number, other format') {
                return plain && s.reg != null;
            }
            if (testCase == 'Namesake') {
                return s.namesake && s.dupKind == null;
            }
            if (testCase == 'Accent / apostrophe variant') {
                return plain && (VolumeTestData.stripAccents(s.first) != s.first || VolumeTestData.stripAccents(s.last) != s.last || s.last.contains('\''));
            }
            return plain;
        }

        private Map<String, List<String>> firstsByLast;

        private Boolean similarToAnyFirst(String first, String last) {
            if (firstsByLast == null) {
                firstsByLast = new Map<String, List<String>>();
                for (HcpSpec s : hcps) {
                    if (!firstsByLast.containsKey(s.last)) {
                        firstsByLast.put(s.last, new List<String>());
                    }
                    firstsByLast.get(s.last).add(HcpMatchEngine.normalizeName(s.first));
                }
            }
            String nf = HcpMatchEngine.normalizeName(first);
            List<String> firsts = firstsByLast.get(last);
            if (firsts != null) {
                for (String other : firsts) {
                    if (HcpMatchEngine.close(nf, other, MatchingConfig.get())) {
                        return true;
                    }
                }
            }
            return false;
        }

        // -------------------------------------------------------- text helpers

        private String institutionalEmail(String first, String last, String domain, Integer format) {
            String f = HcpMatchEngine.normalizeName(first);
            String l = HcpMatchEngine.normalizeName(last);
            String local = format == 0 ? f + '.' + l : (format == 1 ? f.left(1) + '.' + l : (format == 2 ? f.left(1) + l : f + '.' + l + '2'));
            return unique(local, domain);
        }

        private String personalEmail(String first, String last) {
            String f = HcpMatchEngine.normalizeName(first);
            String l = HcpMatchEngine.normalizeName(last);
            String local = rnd(2) == 0 ? f + '.' + l : f + l + String.valueOf(50 + rnd(49));
            return unique(local, pick(VolumeTestData.PERSONAL_DOMAINS));
        }

        private String unique(String local, String domain) {
            String e = local + '@' + domain;
            while (usedEmails.contains(e)) {
                emailSeq++;
                e = local + emailSeq + '@' + domain;
            }
            usedEmails.add(e);
            return e;
        }

        private String regVariant(String reg, Integer k) {
            String prov = reg.substringBefore('-');
            String num = reg.substringAfter('-');
            Integer v = Math.mod(k, 3);
            return v == 0 ? prov.toLowerCase() + ' ' + num : (v == 1 ? prov + '/' + num : prov + '-0' + num);
        }

        private String nameKey(String first, String last) {
            return HcpMatchEngine.normalizeName(first) + '|' + HcpMatchEngine.normalizeName(last);
        }

        private void addTimes(List<String> target, String value, Integer times) {
            for (Integer i = 0; i < times; i++) {
                target.add(value);
            }
        }
    }

    /** One plausible typing error: a doubled letter typed once, else two letters swapped. */
    public static String typo(String value) {
        for (String dbl : new List<String>{ 'll', 'tt', 'ss', 'rr', 'nn', 'cc', 'zz', 'pp', 'mm', 'ff', 'gg' }) {
            if (value.contains(dbl)) {
                return value.replaceFirst(dbl, dbl.left(1));
            }
        }
        if (value.length() >= 5) {
            Integer i = value.length() / 2;
            return value.left(i - 1) + value.substring(i, i + 1) + value.substring(i - 1, i) + value.substring(i + 1);
        }
        return value + 'i';
    }

    public static String stripAccents(String value) {
        if (value == null) {
            return null;
        }
        String out = value;
        Map<String, String> m = new Map<String, String>{
            'à' => 'a', 'á' => 'a', 'è' => 'e', 'é' => 'e', 'ì' => 'i', 'í' => 'i', 'ò' => 'o', 'ó' => 'o', 'ù' => 'u', 'ú' => 'u'
        };
        for (String k : m.keySet()) {
            out = out.replace(k, m.get(k));
        }
        return out;
    }

    // ------------------------------------------------------------ reference data

    public static final List<String> DEPARTMENT_TYPES = new List<String>{
        'Neonatology',
        'Paediatric Gastroenterology',
        'Neonatal Intensive Care',
        'Paediatric Allergy',
        'Paediatric Emergency',
        'Obstetrics & Gynaecology',
        'Clinical Nutrition',
        'Paediatric Endocrinology',
        'Paediatric Surgery'
    };

    /** name, city, province, institutional domain, aliases (fictitious "-example.it" domains). */
    public static final List<List<String>> HOSPITALS = new List<List<String>>{
        new List<String>{ 'Ospedale Niguarda', 'Milan', 'MI', 'niguarda-example.it', 'Niguarda; Ca Granda Niguarda' },
        new List<String>{ 'Ospedale dei Bambini Vittore Buzzi', 'Milan', 'MI', 'buzzi-example.it', 'Buzzi; Ospedale Buzzi' },
        new List<String>{ 'Ospedale San Gerardo', 'Monza', 'MB', 'sangerardo-example.it', 'San Gerardo; IRCCS San Gerardo' },
        new List<String>{ 'Spedali Civili', 'Brescia', 'BS', 'spedalicivili-example.it', 'Civili Brescia; ASST Spedali Civili' },
        new List<String>{ 'Policlinico San Matteo', 'Pavia', 'PV', 'sanmatteo-example.it', 'San Matteo; IRCCS San Matteo' },
        new List<String>{ 'Ospedale Mauriziano', 'Turin', 'TO', 'mauriziano-example.it', 'Mauriziano; Ospedale Umberto I Torino' },
        new List<String>{ 'Ospedale Maggiore della Carità', 'Novara', 'NO', 'maggiorenovara-example.it', 'Maggiore Novara; AOU Novara' },
        new List<String>{ 'Ospedale Galliera', 'Genoa', 'GE', 'galliera-example.it', 'Galliera; EO Galliera' },
        new List<String>{ 'Ospedale Ca\' Foncello', 'Treviso', 'TV', 'foncello-example.it', 'Ca Foncello; Ospedale di Treviso' },
        new List<String>{ 'Ospedale dell\'Angelo', 'Venice', 'VE', 'angelo-example.it', 'Angelo Mestre; Ospedale di Mestre' },
        new List<String>{ 'Ospedale Santa Maria della Misericordia', 'Udine', 'UD', 'asufc-example.it', 'Misericordia Udine; ASUFC' },
        new List<String>{ 'IRCCS Burlo Garofolo', 'Trieste', 'TS', 'burlo-example.it', 'Burlo; Burlo Garofolo' },
        new List<String>{ 'Ospedale Maggiore', 'Bologna', 'BO', 'ausl-bo-example.it', 'Maggiore Bologna; AUSL Bologna' },
        new List<String>{ 'Policlinico di Modena', 'Modena', 'MO', 'policlinico-mo-example.it', 'Policlinico Modena; AOU Modena' },
        new List<String>{ 'Ospedale Maggiore di Parma', 'Parma', 'PR', 'ao-pr-example.it', 'Maggiore Parma; AOU Parma' },
        new List<String>{ 'Arcispedale Santa Maria Nuova', 'Reggio Emilia', 'RE', 'ausl-re-example.it', 'Santa Maria Nuova; ASMN' },
        new List<String>{ 'Ospedale Careggi', 'Florence', 'FI', 'careggi-example.it', 'Careggi; AOU Careggi' },
        new List<String>{ 'Ospedale Santa Chiara', 'Pisa', 'PI', 'aoupisa-example.it', 'Santa Chiara Pisa; AOU Pisana' },
        new List<String>{ 'Policlinico Le Scotte', 'Siena', 'SI', 'aou-siena-example.it', 'Le Scotte; AOU Senese' },
        new List<String>{ 'Ospedale Salesi', 'Ancona', 'AN', 'salesi-example.it', 'Salesi; Ospedali Riuniti Ancona' },
        new List<String>{ 'Ospedale Santa Maria della Misericordia', 'Perugia', 'PG', 'ospedale-pg-example.it', 'Misericordia Perugia; AO Perugia' },
        new List<String>{ 'Policlinico Gemelli', 'Rome', 'RM', 'gemelli-example.it', 'Gemelli; Fondazione Policlinico Gemelli' },
        new List<String>{ 'Policlinico Umberto I', 'Rome', 'RM', 'umberto1-example.it', 'Umberto I; Policlinico Umberto Primo' },
        new List<String>{ 'Ospedale San Camillo', 'Rome', 'RM', 'scamillo-example.it', 'San Camillo; San Camillo Forlanini' },
        new List<String>{ 'AORN Cardarelli', 'Naples', 'NA', 'cardarelli-example.it', 'Cardarelli; Ospedale Cardarelli' },
        new List<String>{ 'Policlinico Federico II', 'Naples', 'NA', 'unina-example.it', 'Federico II; AOU Federico II' },
        new List<String>{ 'Ospedale Pediatrico Giovanni XXIII', 'Bari', 'BA', 'giovanni23-example.it', 'Giovanni XXIII Bari; Pediatrico Bari' },
        new List<String>{ 'Policlinico di Bari', 'Bari', 'BA', 'policlinico-ba-example.it', 'Policlinico Bari; AOU Consorziale' },
        new List<String>{ 'ARNAS Civico', 'Palermo', 'PA', 'arnascivico-example.it', 'Civico Palermo; Di Cristina' },
        new List<String>{ 'Ospedale Brotzu', 'Cagliari', 'CA', 'brotzu-example.it', 'Brotzu; ARNAS Brotzu' }
    };

    public static final List<String> MALE = new List<String>{
        'Alessandro', 'Andrea', 'Antonio', 'Davide', 'Emanuele', 'Fabio', 'Federico', 'Filippo', 'Francesco', 'Gabriele',
        'Giacomo', 'Giovanni', 'Giuseppe', 'Lorenzo', 'Luca', 'Luigi', 'Massimo', 'Matteo', 'Mattia', 'Michele',
        'Nicolò', 'Niccolò', 'Paolo', 'Pietro', 'Riccardo', 'Roberto', 'Simone', 'Stefano', 'Tommaso', 'Vincenzo',
        'Salvatore', 'Enrico', 'Carlo', 'Daniele', 'Alberto', 'Noè', 'Elia', 'Gianluca', 'Raffaele', 'Ugo'
    };

    public static final List<String> FEMALE = new List<String>{
        'Alessandra', 'Alessia', 'Anna', 'Beatrice', 'Camilla', 'Caterina', 'Chiara', 'Claudia', 'Cristina', 'Elena',
        'Elisa', 'Federica', 'Francesca', 'Giorgia', 'Giulia', 'Ilaria', 'Laura', 'Lucia', 'Marta', 'Martina',
        'Michela', 'Monica', 'Paola', 'Roberta', 'Sara', 'Silvia', 'Simona', 'Valentina', 'Valeria', 'Veronica',
        'Noemi', 'Zoe', 'Irene', 'Serena', 'Debora', 'Agnese', 'Benedetta', 'Ludovica', 'Rebecca', 'Gaia'
    };

    /** The mockup surnames (and look-alikes) are left out so the mockup demo keeps its outcomes. */
    public static final List<String> SURNAMES = new List<String>{
        'Russo', 'Colombo', 'Ricci', 'Marino', 'Bruno', 'Costa', 'Giordano', 'Mancini', 'Lombardi', 'Moretti',
        'Barbieri', 'Fontana', 'Santoro', 'Mariani', 'Caruso', 'Fabbri', 'Martini', 'Ferraro', 'Testa', 'Serra',
        'Pellegrini', 'Marini', 'Gentile', 'Farina', 'Vitale', 'Lombardo', 'Coppola', 'De Luca', 'D\'Amico', 'Bernardi',
        'Cattaneo', 'Fiore', 'Messina', 'Monti', 'Morelli', 'Amato', 'Silvestri', 'Mazza', 'Parisi', 'Grasso',
        'Sartori', 'Martinelli', 'De Santis', 'Ferrara', 'Bellini', 'Basile', 'Riva', 'Donati', 'Piras', 'Vitali',
        'Battaglia', 'Neri', 'Sanna', 'Fumagalli', 'Palumbo', 'Gatti', 'Orlando', 'Valentini', 'Pagano', 'Ruggiero',
        'Bassi', 'Montanari', 'Carbone', 'Grassi', 'Dell\'Acqua', 'Lo Russo', 'Cantù', 'Pirrò', 'Nicolò', 'Di Stefano',
        'Di Pietro', 'La Rosa', 'Sorrentino', 'Rizzo', 'Longo', 'Mazzola', 'Ferrero', 'Gualtieri', 'Zanetti', 'Zanella',
        'Bonetti', 'Pace', 'Ceccarelli', 'Melis', 'Mura', 'Porcu', 'Cocco', 'Spina', 'Guerra', 'Benassi',
        'Capone', 'Palmieri', 'Tedesco', 'Negri', 'Morandi', 'Guidi', 'Fiorentino', 'Ventura', 'Mele', 'Bertolini',
        'Brambilla', 'Colonna', 'Cirillo', 'Pozzi', 'Rota', 'Bonomi', 'Locatelli', 'Pagani', 'Crippa', 'Mauri',
        'Galbiati', 'Vismara', 'Sant\'Elia', 'Cassano', 'Marchesi', 'Pastore', 'Ferretti', 'Bonfanti', 'Rinaldelli', 'Gallucci',
        'Mancuso', 'Romagnoli', 'Barone', 'Cristiani', 'Gallina', 'Arena', 'Bianco Ferrante', 'Sala Bolognini', 'Mastroianni', 'Lucchesi'
    };

    /** Surnames that exist nowhere else in the data (really new HCPs). */
    public static final List<String> NEW_SURNAMES = new List<String>{
        'Quaglia', 'Zoccoli', 'Brugnoli', 'Tamburini', 'Scarpellini', 'Vezzosi', 'Guzzardi', 'Iacobelli', 'Ottaviani', 'Pugliatti',
        'Uboldi', 'Xausa', 'Yaccarino', 'Wolfsgruber', 'Kofler', 'Hofer', 'Jannuzzi', 'Quarantotto', 'Zuccherelli', 'Ventrella',
        'Turchetti', 'Squarzoni', 'Ruzzenenti', 'Pinciroli', 'Oddenino'
    };

    public static final List<String> PERSONAL_DOMAINS = new List<String>{ 'gmail.com', 'libero.it', 'yahoo.it', 'hotmail.it', 'outlook.it' };

    public static final List<String> ROLES = new List<String>{ 'Consultant', 'Consultant', 'Consultant', 'Head of department', 'Resident', 'Dietitian', 'Nurse' };
}
