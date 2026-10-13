/**
 * Measures matching accuracy on the generated test captures (Expected_Outcome__c / Expected_Contact__c),
 * shown in the "Accuracy" tab of the Matching & Duplicates workbench. Also starts the volume generator.
 *
 * A match counts as correct when the matched HCP is the expected one, or a known duplicate record of it
 * (Contact.Test_Duplicate_Of__c), because both records are the same person.
 */
public without sharing class MatchingAccuracyController {
    public class Metrics {
        @AuraEnabled
        public Integer total = 0;
        @AuraEnabled
        public Integer pending = 0;
        @AuraEnabled
        public Integer autoCount = 0;
        @AuraEnabled
        public Integer autoCorrect = 0;
        @AuraEnabled
        public Decimal autoPrecision;
        @AuraEnabled
        public Integer reviewCount = 0;
        @AuraEnabled
        public Decimal reviewRate;
        @AuraEnabled
        public Integer newCount = 0;
        @AuraEnabled
        public Integer falseNew = 0;
        @AuraEnabled
        public Integer withExistingHcp = 0;
        @AuraEnabled
        public Decimal falseNewRate;
        @AuraEnabled
        public Integer missedAuto = 0;
        @AuraEnabled
        public Decimal reviewRecall;
        @AuraEnabled
        public Decimal reviewTop1;
        @AuraEnabled
        public Decimal outcomeAgreement;
        @AuraEnabled
        public List<CaseRow> byCase = new List<CaseRow>();
        @AuraEnabled
        public List<Problem> problems = new List<Problem>();
        @AuraEnabled
        public Integer hospitals = 0;
        @AuraEnabled
        public Integer departments = 0;
        @AuraEnabled
        public Integer hcps = 0;
        @AuraEnabled
        public Integer knownDuplicates = 0;
        @AuraEnabled
        public Integer duplicatePairs = 0;
        @AuraEnabled
        public Integer knownDuplicatesFound = 0;
        @AuraEnabled
        public Decimal duplicateRecall;
        @AuraEnabled
        public Decimal duplicatePrecision;
        @AuraEnabled
        public String jobStatus;
    }

    public class CaseRow {
        @AuraEnabled
        public String testCase;
        @AuraEnabled
        public String expected;
        @AuraEnabled
        public Integer total = 0;
        @AuraEnabled
        public Integer autoCount = 0;
        @AuraEnabled
        public Integer reviewCount = 0;
        @AuraEnabled
        public Integer newCount = 0;
        @AuraEnabled
        public Integer asExpected = 0;
    }

    public class Problem {
        @AuraEnabled
        public String captureId;
        @AuraEnabled
        public String captureName;
        @AuraEnabled
        public String testCase;
        @AuraEnabled
        public String issue;
    }

    private static void checkSteward() {
        if (!FeatureManagement.checkPermission(CaptureConstants.PERM_STEWARD)) {
            throw new AuraHandledException('Only data stewards and admins can use the matching workbench.');
        }
    }

    /** Outcome bucket of a capture: what the engine decided before any person acted. */
    public static String actualOutcome(String matchingStatus) {
        if (matchingStatus == CaptureConstants.MATCH_AUTO) {
            return VolumeTestData.OUT_AUTO;
        }
        if (matchingStatus == CaptureConstants.MATCH_NEW) {
            return VolumeTestData.OUT_NEW;
        }
        if (
            matchingStatus == CaptureConstants.MATCH_REVIEW ||
            matchingStatus == CaptureConstants.MATCH_REVIEWED ||
            matchingStatus == CaptureConstants.MATCH_REVIEWED_NEW ||
            matchingStatus == CaptureConstants.MATCH_DISCARDED
        ) {
            return VolumeTestData.OUT_REVIEW;
        }
        return null;
    }

    @AuraEnabled
    public static Metrics getMetrics() {
        checkSteward();
        Metrics m = new Metrics();
        List<Capture__c> caps = [
            SELECT
                Id,
                Name,
                Matching_Status__c,
                Matched_Contact__c,
                Matched_Contact__r.Test_Duplicate_Of__c,
                Expected_Outcome__c,
                Expected_Contact__c,
                Expected_Contact__r.Test_Duplicate_Of__c,
                Test_Case__c
            FROM Capture__c
            WHERE Expected_Outcome__c != NULL
            ORDER BY Name
            LIMIT 5000
        ];
        Map<Id, List<Capture_Candidate__c>> candidates = new Map<Id, List<Capture_Candidate__c>>();
        for (Capture_Candidate__c cc : [
            SELECT Capture__c, Contact__c, Contact__r.Test_Duplicate_Of__c, Recommended__c
            FROM Capture_Candidate__c
            WHERE Capture__c IN :caps AND Contact__c != NULL
        ]) {
            if (!candidates.containsKey(cc.Capture__c)) {
                candidates.put(cc.Capture__c, new List<Capture_Candidate__c>());
            }
            candidates.get(cc.Capture__c).add(cc);
        }

        Map<String, CaseRow> rows = new Map<String, CaseRow>();
        Integer agree = 0;
        Integer decided = 0;
        Integer reviewWithExpected = 0;
        Integer recallHits = 0;
        Integer top1Hits = 0;
        for (Capture__c c : caps) {
            m.total++;
            String actual = actualOutcome(c.Matching_Status__c);
            String key = c.Test_Case__c == null ? '(no case)' : c.Test_Case__c;
            if (!rows.containsKey(key)) {
                CaseRow r = new CaseRow();
                r.testCase = key;
                r.expected = c.Expected_Outcome__c;
                rows.put(key, r);
            }
            CaseRow row = rows.get(key);
            row.total++;
            if (c.Expected_Contact__c != null) {
                m.withExistingHcp++;
            }
            if (actual == null) {
                m.pending++;
                continue;
            }
            decided++;
            if (actual == c.Expected_Outcome__c) {
                agree++;
                row.asExpected++;
            }
            if (actual == VolumeTestData.OUT_AUTO) {
                m.autoCount++;
                row.autoCount++;
                if (sameHcp(c.Matched_Contact__c, c.Matched_Contact__r?.Test_Duplicate_Of__c, c.Expected_Contact__c, c.Expected_Contact__r?.Test_Duplicate_Of__c)) {
                    m.autoCorrect++;
                } else {
                    addProblem(m, c, c.Expected_Contact__c == null ? 'auto-matched a new HCP to an existing one' : 'auto-matched to the WRONG HCP');
                }
            } else if (actual == VolumeTestData.OUT_REVIEW) {
                m.reviewCount++;
                row.reviewCount++;
                if (c.Expected_Outcome__c == VolumeTestData.OUT_AUTO) {
                    m.missedAuto++;
                }
                if (c.Expected_Contact__c != null) {
                    reviewWithExpected++;
                    Boolean inList = false;
                    Boolean top = false;
                    if (candidates.containsKey(c.Id)) {
                        for (Capture_Candidate__c cc : candidates.get(c.Id)) {
                            if (sameHcp(cc.Contact__c, cc.Contact__r.Test_Duplicate_Of__c, c.Expected_Contact__c, c.Expected_Contact__r?.Test_Duplicate_Of__c)) {
                                inList = true;
                                top = top || cc.Recommended__c;
                            }
                        }
                    }
                    if (inList) {
                        recallHits++;
                    } else {
                        addProblem(m, c, 'real HCP not among the review candidates');
                    }
                    if (top) {
                        top1Hits++;
                    }
                }
            } else {
                m.newCount++;
                row.newCount++;
                if (c.Expected_Contact__c != null) {
                    m.falseNew++;
                    addProblem(m, c, 'new HCP created although the HCP exists');
                }
            }
        }
        m.byCase = rows.values();
        m.autoPrecision = pct(m.autoCorrect, m.autoCount);
        m.reviewRate = pct(m.reviewCount, decided);
        m.falseNewRate = pct(m.falseNew, m.withExistingHcp);
        m.reviewRecall = pct(recallHits, reviewWithExpected);
        m.reviewTop1 = pct(top1Hits, reviewWithExpected);
        m.outcomeAgreement = pct(agree, decided);

        m.hospitals = [SELECT COUNT() FROM Account WHERE RecordType.DeveloperName = :HcoDirectory.RT_HOSPITAL];
        m.departments = [SELECT COUNT() FROM Account WHERE RecordType.DeveloperName = :HcoDirectory.RT_DEPARTMENT];
        m.hcps = [SELECT COUNT() FROM Contact WHERE Test_Data_Set__c = :VolumeTestData.DATA_SET];
        m.knownDuplicates = [SELECT COUNT() FROM Contact WHERE Test_Duplicate_Of__c != NULL];
        Integer volumePairs = 0;
        for (HCP_Duplicate_Pair__c p : [
            SELECT Contact_A__c, Contact_B__c, Contact_A__r.Test_Duplicate_Of__c, Contact_B__r.Test_Duplicate_Of__c, Contact_A__r.Test_Data_Set__c
            FROM HCP_Duplicate_Pair__c
            WHERE Status__c != 'Not a duplicate' AND Contact_A__c != NULL AND Contact_B__c != NULL
            LIMIT 10000
        ]) {
            m.duplicatePairs++;
            if (p.Contact_A__r.Test_Data_Set__c != null) {
                volumePairs++;
            }
            if (p.Contact_A__r.Test_Duplicate_Of__c == p.Contact_B__c || p.Contact_B__r.Test_Duplicate_Of__c == p.Contact_A__c) {
                m.knownDuplicatesFound++;
            }
        }
        m.duplicateRecall = pct(m.knownDuplicatesFound, m.knownDuplicates);
        m.duplicatePrecision = pct(m.knownDuplicatesFound, volumePairs);
        List<AsyncApexJob> jobs = [
            SELECT Status, JobItemsProcessed, TotalJobItems, NumberOfErrors, ExtendedStatus
            FROM AsyncApexJob
            WHERE ApexClass.Name IN ('VolumeTestData', 'DuplicateScanJob') AND JobType = 'BatchApex'
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (!jobs.isEmpty()) {
            AsyncApexJob j = jobs[0];
            m.jobStatus = j.Status + ' (' + j.JobItemsProcessed + '/' + j.TotalJobItems + ' steps' +
                (j.NumberOfErrors > 0 ? ', ' + j.NumberOfErrors + ' failed: ' + j.ExtendedStatus : '') + ')';
        }
        return m;
    }

    private static Boolean sameHcp(Id actual, Id actualDupOf, Id expected, Id expectedDupOf) {
        if (actual == null || expected == null) {
            return false;
        }
        return actual == expected || actualDupOf == expected || expectedDupOf == actual || (actualDupOf != null && actualDupOf == expectedDupOf);
    }

    private static void addProblem(Metrics m, Capture__c c, String issue) {
        if (m.problems.size() >= 50) {
            return;
        }
        Problem p = new Problem();
        p.captureId = c.Id;
        p.captureName = c.Name;
        p.testCase = c.Test_Case__c;
        p.issue = issue;
        m.problems.add(p);
    }

    private static Decimal pct(Integer part, Integer whole) {
        if (whole == null || whole == 0) {
            return null;
        }
        return (Decimal.valueOf(part) * 100 / whole).setScale(1);
    }

    // ------------------------------------------------------------ generator actions (stewards / admins)

    /** action: generate | captures | cleanup. Returns the batch job Id. */
    @AuraEnabled
    public static String runGenerator(String action) {
        checkSteward();
        if (action == 'generate') {
            return VolumeTestData.generate();
        }
        if (action == 'captures') {
            return VolumeTestData.regenerateCaptures();
        }
        if (action == 'cleanup') {
            return VolumeTestData.cleanup();
        }
        throw new AuraHandledException('Unknown action.');
    }
}
