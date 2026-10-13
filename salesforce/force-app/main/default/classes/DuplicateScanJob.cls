/**
 * Finds possible duplicate HCPs with the same engine used for capture matching (HcpMatchEngine)
 * and stores them as HCP_Duplicate_Pair__c (Open). Pairs a steward marked "Not a duplicate" or
 * that were merged are never proposed again.
 *
 * Blocking keeps it fast: one batch step per initial letter (an HCP is in the block of its surname
 * and of its first name, so swapped names meet), plus a last step for HCPs sharing an email or a
 * registration number whatever their name.
 *
 *   Database.executeBatch(new DuplicateScanJob(), 1);
 */
public without sharing class DuplicateScanJob implements Database.Batchable<String> {
    public static final String STATUS_OPEN = 'Open';
    public static final String STATUS_NOT_DUPLICATE = 'Not a duplicate';
    public static final String STATUS_MERGED = 'Merged';
    public static final String IDENTIFIERS = '#identifiers';
    private static final String FIELDS = 'SELECT Id, FirstName, LastName, Email, Specialty__c, MailingCity, Registration_Number__c, Registration_Key__c, OneKey_Id__c, AccountId, Account.Name FROM Contact ';

    public Iterable<String> start(Database.BatchableContext bc) {
        List<String> blocks = new List<String>();
        for (String letter : 'abcdefghijklmnopqrstuvwxyz'.split('')) {
            blocks.add(letter);
        }
        blocks.add(IDENTIFIERS);
        return blocks;
    }

    public void execute(Database.BatchableContext bc, List<String> scope) {
        for (String block : scope) {
            scanBlock(block);
        }
    }

    public void finish(Database.BatchableContext bc) {
        System.debug(LoggingLevel.INFO, 'Duplicate scan finished');
    }

    public static Id run() {
        return Database.executeBatch(new DuplicateScanJob(), 1);
    }

    /** Scores all candidate pairs in one block and upserts them. Returns the number of pairs found. */
    public static Integer scanBlock(String block) {
        List<Contact> contacts;
        if (block == IDENTIFIERS) {
            contacts = identifierGroups();
        } else {
            String likePattern = block + '%';
            contacts = Database.query(FIELDS + 'WHERE LastName LIKE :likePattern OR FirstName LIKE :likePattern ORDER BY Id LIMIT 10000');
        }
        Map<Id, HcpMatchEngine.Profile> profiles = HcpMatchEngine.fromContacts(contacts);
        List<HcpMatchEngine.Profile> list1 = profiles.values();
        for (HcpMatchEngine.Profile p : list1) {
            p.prepare();
        }
        MatchingConfig cfg = MatchingConfig.get();
        Map<String, HCP_Duplicate_Pair__c> found = new Map<String, HCP_Duplicate_Pair__c>();
        for (Integer i = 0; i < list1.size(); i++) {
            HcpMatchEngine.Profile a = list1[i];
            for (Integer j = i + 1; j < list1.size(); j++) {
                HcpMatchEngine.Profile b = list1[j];
                if (!worthComparing(a, b, block, cfg)) {
                    continue;
                }
                HcpMatchEngine.Comparison cmp = HcpMatchEngine.compare(a, b);
                if (!cmp.isCandidate() || cmp.score < cfg.duplicateMinScore) {
                    continue;
                }
                HCP_Duplicate_Pair__c pair = toPair(a, b, cmp);
                found.put(pair.Pair_Key__c, pair);
            }
        }
        return save(found);
    }

    /** Cheap pre-filter before the full comparison. */
    private static Boolean worthComparing(HcpMatchEngine.Profile a, HcpMatchEngine.Profile b, String block, MatchingConfig cfg) {
        if (String.isNotBlank(a.nEmail) && a.nEmail == b.nEmail) {
            return true;
        }
        if (String.isNotBlank(a.regKey) && a.regKey == b.regKey) {
            return true;
        }
        if (block == IDENTIFIERS) {
            return false;
        }
        // compare a pair once: in the block of the first letter of A's surname or first name
        if (!a.nLast.startsWith(block) && !b.nLast.startsWith(block)) {
            return false;
        }
        if (a.nLast == b.nLast || HcpMatchEngine.close(a.nLast, b.nLast, cfg)) {
            return true;
        }
        return HcpMatchEngine.close(a.nLast, b.nFirst, cfg) && HcpMatchEngine.close(a.nFirst, b.nLast, cfg);
    }

    private static List<Contact> identifierGroups() {
        Set<String> emails = new Set<String>();
        for (AggregateResult r : [SELECT Email e FROM Contact WHERE Email != NULL GROUP BY Email HAVING COUNT(Id) > 1 LIMIT 2000]) {
            emails.add((String) r.get('e'));
        }
        Set<String> regs = new Set<String>();
        for (AggregateResult r : [
            SELECT Registration_Number__c rn
            FROM Contact
            WHERE Registration_Number__c != NULL
            GROUP BY Registration_Number__c
            HAVING COUNT(Id) > 1
            LIMIT 2000
        ]) {
            regs.add((String) r.get('rn'));
        }
        // registration numbers typed differently ("MI-20418" / "MI 20418") meet through their digits
        List<String> digitLikes = new List<String>{ '#none#' };
        Map<String, Integer> digitCount = new Map<String, Integer>();
        for (Contact c : [SELECT Registration_Number__c FROM Contact WHERE Registration_Number__c != NULL LIMIT 50000]) {
            String d = HcpMatchEngine.registrationDigits(HcpMatchEngine.registrationKey(c.Registration_Number__c));
            if (d.length() >= 4) {
                digitCount.put(d, digitCount.containsKey(d) ? digitCount.get(d) + 1 : 1);
            }
        }
        for (String d : digitCount.keySet()) {
            if (digitCount.get(d) > 1 && digitLikes.size() < 1000) {
                digitLikes.add('%' + d);
            }
        }
        return Database.query(
            FIELDS + 'WHERE Email IN :emails OR Registration_Number__c IN :regs OR Registration_Key__c LIKE :digitLikes ORDER BY Id LIMIT 10000'
        );
    }

    public static String pairKey(Id a, Id b) {
        // 18-character Ids: the key field is unique case-insensitively
        String x = String.valueOf(a);
        String y = String.valueOf(b);
        return x.compareTo(y) < 0 ? x + '-' + y : y + '-' + x;
    }

    private static HCP_Duplicate_Pair__c toPair(HcpMatchEngine.Profile a, HcpMatchEngine.Profile b, HcpMatchEngine.Comparison cmp) {
        HcoDirectory dir = HcoDirectory.get();
        Set<Id> hospitals = new Set<Id>(a.hospitalIds);
        hospitals.addAll(b.hospitalIds);
        Set<Id> departments = new Set<Id>(a.departmentIds);
        departments.addAll(b.departmentIds);
        List<String> hNames = new List<String>();
        List<String> hIds = new List<String>();
        for (Id h : hospitals) {
            hNames.add(dir.hospitalName(h));
            hIds.add(String.valueOf(h));
        }
        List<String> dNames = new List<String>();
        List<String> dIds = new List<String>();
        for (Id d : departments) {
            dNames.add(dir.label(d));
            dIds.add(String.valueOf(d));
        }
        Boolean aFirst = String.valueOf(a.recordId).compareTo(String.valueOf(b.recordId)) < 0;
        return new HCP_Duplicate_Pair__c(
            Contact_A__c = aFirst ? a.recordId : b.recordId,
            Contact_B__c = aFirst ? b.recordId : a.recordId,
            Pair_Key__c = pairKey(a.recordId, b.recordId),
            Score__c = cmp.score,
            Name_Match__c = cmp.nameFlag,
            Email_Match__c = cmp.emailFlag,
            Reg_Number_Match__c = cmp.regFlag,
            Organisation_Match__c = cmp.orgFlag,
            Specialty_Match__c = cmp.specialtyFlag,
            City_Match__c = cmp.cityFlag,
            Score_Explanation__c = cmp.explanationText(),
            Hospital_Names__c = String.join(hNames, '; ').left(255),
            Department_Names__c = String.join(dNames, '; ').left(255),
            Hospital_Ids__c = String.join(hIds, ',').left(255),
            Department_Ids__c = String.join(dIds, ',').left(255),
            Last_Scanned_At__c = System.now()
        );
    }

    /** Inserts new pairs, refreshes open ones, leaves decided ones (not a duplicate / merged) alone. */
    private static Integer save(Map<String, HCP_Duplicate_Pair__c> found) {
        if (found.isEmpty()) {
            return 0;
        }
        Map<String, HCP_Duplicate_Pair__c> existing = new Map<String, HCP_Duplicate_Pair__c>();
        for (HCP_Duplicate_Pair__c p : [SELECT Id, Pair_Key__c, Status__c FROM HCP_Duplicate_Pair__c WHERE Pair_Key__c IN :found.keySet()]) {
            existing.put(p.Pair_Key__c, p);
        }
        List<HCP_Duplicate_Pair__c> inserts = new List<HCP_Duplicate_Pair__c>();
        List<HCP_Duplicate_Pair__c> updates = new List<HCP_Duplicate_Pair__c>();
        for (String k : found.keySet()) {
            HCP_Duplicate_Pair__c p = found.get(k);
            HCP_Duplicate_Pair__c old = existing.get(k);
            if (old == null) {
                p.Status__c = STATUS_OPEN;
                inserts.add(p);
            } else if (old.Status__c == STATUS_OPEN) {
                p.Id = old.Id;
                updates.add(p);
            }
        }
        insert inserts;
        // lookups are not changed on refresh (same pair key = same two HCPs)
        List<HCP_Duplicate_Pair__c> refresh = new List<HCP_Duplicate_Pair__c>();
        for (HCP_Duplicate_Pair__c p : updates) {
            refresh.add(
                new HCP_Duplicate_Pair__c(
                    Id = p.Id,
                    Score__c = p.Score__c,
                    Name_Match__c = p.Name_Match__c,
                    Email_Match__c = p.Email_Match__c,
                    Reg_Number_Match__c = p.Reg_Number_Match__c,
                    Organisation_Match__c = p.Organisation_Match__c,
                    Specialty_Match__c = p.Specialty_Match__c,
                    City_Match__c = p.City_Match__c,
                    Score_Explanation__c = p.Score_Explanation__c,
                    Hospital_Names__c = p.Hospital_Names__c,
                    Department_Names__c = p.Department_Names__c,
                    Hospital_Ids__c = p.Hospital_Ids__c,
                    Department_Ids__c = p.Department_Ids__c,
                    Last_Scanned_At__c = p.Last_Scanned_At__c
                )
            );
        }
        update refresh;
        return inserts.size() + refresh.size();
    }
}
