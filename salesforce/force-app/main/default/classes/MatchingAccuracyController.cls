/**
 * "Accuracy" tab of the Matching workbench.
 *
 * - Per congress (getEventMetrics): what matching did with the real captures of one congress, or of all
 *   of them: auto-matched by rule, sent to review and how stewards resolved it, new HCPs, registrations
 *   not found, confidence, review backlog. Read live from Capture__c / Capture_Candidate__c.
 * - Test set (getMetrics): precision against the expected outcome of the generated test captures
 *   (Expected_Outcome__c / Expected_Contact__c). A match counts as correct when the matched HCP is the
 *   expected one, or a known duplicate record of it (Contact.Test_Duplicate_Of__c), because both
 *   records are the same person.
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
        List<AsyncApexJob> jobs = [
            SELECT Status, JobItemsProcessed, TotalJobItems, NumberOfErrors, ExtendedStatus
            FROM AsyncApexJob
            WHERE ApexClass.Name = 'VolumeTestData' AND JobType = 'BatchApex'
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


    // ------------------------------------------------------------ real congresses

    public static final String RULE_REP = 'HCP selected by rep';
    public static final String RULE_EMAIL = 'Identical email';
    public static final String RULE_REGISTRATION = 'Identical registration number';

    public class EventOption {
        @AuraEnabled
        public String value;
        @AuraEnabled
        public String label;
        @AuraEnabled
        public Integer captures = 0;
    }

    public class ChannelCount {
        @AuraEnabled
        public String label;
        @AuraEnabled
        public Integer count = 0;
    }

    /** Matching figures of the real captures of one congress (or of all congresses in the "All" row). */
    public class EventMetrics {
        @AuraEnabled
        public String eventId;
        @AuraEnabled
        public String eventName;
        @AuraEnabled
        public Integer total = 0;
        @AuraEnabled
        public List<ChannelCount> byChannel = new List<ChannelCount>();
        /** Matched or decided by the engine or a steward (total minus queued and errors). */
        @AuraEnabled
        public Integer processed = 0;
        @AuraEnabled
        public Integer queued = 0;
        @AuraEnabled
        public Integer errors = 0;
        @AuraEnabled
        public Integer autoCount = 0;
        @AuraEnabled
        public Decimal autoRate;
        @AuraEnabled
        public Integer autoByRep = 0;
        @AuraEnabled
        public Integer autoByEmail = 0;
        @AuraEnabled
        public Integer autoByRegistration = 0;
        /** Sent to a person: still to review + reviewed (matched, new HCP, discarded). */
        @AuraEnabled
        public Integer sentToReview = 0;
        @AuraEnabled
        public Decimal reviewRate;
        @AuraEnabled
        public Integer backlog = 0;
        /** Minutes the oldest capture still to review has been waiting. */
        @AuraEnabled
        public Integer oldestWaitingMinutes;
        @AuraEnabled
        public Integer reviewedMatched = 0;
        @AuraEnabled
        public Integer reviewedNew = 0;
        @AuraEnabled
        public Integer reviewedDiscarded = 0;
        /** Average minutes from capture to the steward's decision. */
        @AuraEnabled
        public Integer avgReviewMinutes;
        /** Reviewed - matched to the candidate the engine recommended first. */
        @AuraEnabled
        public Integer recommendationAccepted = 0;
        @AuraEnabled
        public Decimal recommendationAcceptedRate;
        @AuraEnabled
        public Integer newHcp = 0;
        @AuraEnabled
        public Integer registrationNotFound = 0;
        @AuraEnabled
        public Integer confidenceHigh = 0;
        @AuraEnabled
        public Integer confidenceMedium = 0;
        @AuraEnabled
        public Integer confidenceLow = 0;
        /** Average score of the recommended candidate of the captures sent to review. */
        @AuraEnabled
        public Decimal avgTopScore;
        /** Only for "All congresses": one row per congress. */
        @AuraEnabled
        public List<EventMetrics> byEvent = new List<EventMetrics>();
        @AuraEnabled
        public String refreshedAt;

        // running totals, not sent to the page
        public Map<String, ChannelCount> channels = new Map<String, ChannelCount>();
        public Decimal topScoreSum = 0;
        public Integer topScoreCount = 0;
        public Long reviewMinutesSum = 0;
        public Integer reviewMinutesCount = 0;
    }

    /** Congresses with real captures (the synthetic test event excluded), most recent first. */
    @AuraEnabled
    public static List<EventOption> getEventOptions() {
        checkSteward();
        Map<Id, Integer> counts = new Map<Id, Integer>();
        for (AggregateResult ar : [
            SELECT Event__c ev, COUNT(Id) n
            FROM Capture__c
            WHERE Expected_Outcome__c = NULL AND Event__c != NULL
            GROUP BY Event__c
        ]) {
            counts.put((Id) ar.get('ev'), (Integer) ar.get('n'));
        }
        List<EventOption> out = new List<EventOption>();
        for (Event__c e : [
            SELECT Id, Name, Start_Date__c
            FROM Event__c
            WHERE Name != :VolumeTestData.TEST_EVENT_NAME
            ORDER BY Start_Date__c DESC NULLS LAST, Name
            LIMIT 200
        ]) {
            EventOption o = new EventOption();
            o.value = e.Id;
            o.label = e.Name;
            o.captures = counts.containsKey(e.Id) ? counts.get(e.Id) : 0;
            out.add(o);
        }
        return out;
    }

    /** eventId empty = all congresses, with one row per congress in byEvent. */
    @AuraEnabled
    public static EventMetrics getEventMetrics(String eventId) {
        checkSteward();
        Id evId = String.isBlank(eventId) ? null : Id.valueOf(eventId);
        String q =
            'SELECT Id, Event__c, Event__r.Name, Channel__c, Matching_Status__c, Match_Rule__c, Matched_Contact__c, ' +
            'Suggestion_Confidence__c, Captured_At__c, CreatedDate, Reviewed_At__c ' +
            'FROM Capture__c WHERE Expected_Outcome__c = NULL AND Event__c != NULL';
        if (evId != null) {
            q += ' AND Event__c = :evId';
        }
        q += ' ORDER BY Captured_At__c ASC LIMIT 20000';
        List<Capture__c> caps = Database.query(q);

        // recommended candidate (rank 1) of every capture that went to review
        Set<Id> reviewIds = new Set<Id>();
        for (Capture__c c : caps) {
            if (wentToReview(c)) {
                reviewIds.add(c.Id);
            }
        }
        Map<Id, Capture_Candidate__c> top = new Map<Id, Capture_Candidate__c>();
        for (Capture_Candidate__c cc : [
            SELECT Capture__c, Contact__c, Score__c
            FROM Capture_Candidate__c
            WHERE Capture__c IN :reviewIds AND Recommended__c = TRUE
        ]) {
            top.put(cc.Capture__c, cc);
        }

        EventMetrics summary = new EventMetrics();
        Map<Id, EventMetrics> perEvent = new Map<Id, EventMetrics>();
        Datetime now = System.now();
        for (Capture__c c : caps) {
            if (!perEvent.containsKey(c.Event__c)) {
                EventMetrics em = new EventMetrics();
                em.eventId = c.Event__c;
                em.eventName = c.Event__r.Name;
                perEvent.put(c.Event__c, em);
            }
            add(summary, c, top.get(c.Id), now);
            add(perEvent.get(c.Event__c), c, top.get(c.Id), now);
        }
        finish(summary);
        if (evId != null) {
            List<Event__c> evs = [SELECT Name FROM Event__c WHERE Id = :evId];
            summary.eventId = evId;
            summary.eventName = evs.isEmpty() ? null : evs[0].Name;
        } else {
            for (EventMetrics em : perEvent.values()) {
                finish(em);
                summary.byEvent.add(em);
            }
        }
        summary.refreshedAt = now.format('HH:mm:ss');
        return summary;
    }

    private static Boolean wentToReview(Capture__c c) {
        String st = c.Matching_Status__c;
        return st == CaptureConstants.MATCH_REVIEW ||
            st == CaptureConstants.MATCH_REVIEWED ||
            st == CaptureConstants.MATCH_REVIEWED_NEW ||
            (st == CaptureConstants.MATCH_DISCARDED && c.Match_Rule__c != CaptureConstants.RULE_REGISTRATION_NOT_FOUND);
    }

    private static void add(EventMetrics m, Capture__c c, Capture_Candidate__c rec, Datetime now) {
        m.total++;
        String channel = String.isBlank(c.Channel__c) ? '(none)' : c.Channel__c;
        if (!m.channels.containsKey(channel)) {
            ChannelCount k = new ChannelCount();
            k.label = channel;
            m.channels.put(channel, k);
            m.byChannel.add(k);
        }
        m.channels.get(channel).count++;

        String st = c.Matching_Status__c;
        if (st == CaptureConstants.MATCH_QUEUED || st == null) {
            m.queued++;
            return;
        }
        if (st == CaptureConstants.MATCH_ERROR) {
            m.errors++;
            return;
        }
        m.processed++;
        if (st == CaptureConstants.MATCH_AUTO) {
            m.autoCount++;
            if (c.Match_Rule__c == RULE_REP) {
                m.autoByRep++;
            } else if (c.Match_Rule__c == RULE_EMAIL) {
                m.autoByEmail++;
            } else if (c.Match_Rule__c == RULE_REGISTRATION) {
                m.autoByRegistration++;
            }
            return;
        }
        if (st == CaptureConstants.MATCH_NEW) {
            m.newHcp++;
            return;
        }
        if (!wentToReview(c)) {
            m.registrationNotFound++;
            return;
        }
        m.sentToReview++;
        if (c.Suggestion_Confidence__c == 'High') {
            m.confidenceHigh++;
        } else if (c.Suggestion_Confidence__c == 'Medium') {
            m.confidenceMedium++;
        } else if (c.Suggestion_Confidence__c == 'Low') {
            m.confidenceLow++;
        }
        if (rec != null && rec.Score__c != null) {
            m.topScoreSum += rec.Score__c;
            m.topScoreCount++;
        }
        Datetime capturedAt = c.Captured_At__c == null ? c.CreatedDate : c.Captured_At__c;
        if (st == CaptureConstants.MATCH_REVIEW) {
            m.backlog++;
            Integer waiting = minutesBetween(capturedAt, now);
            if (waiting != null && (m.oldestWaitingMinutes == null || waiting > m.oldestWaitingMinutes)) {
                m.oldestWaitingMinutes = waiting;
            }
            return;
        }
        if (st == CaptureConstants.MATCH_REVIEWED) {
            m.reviewedMatched++;
            if (rec != null && rec.Contact__c == c.Matched_Contact__c) {
                m.recommendationAccepted++;
            }
        } else if (st == CaptureConstants.MATCH_REVIEWED_NEW) {
            m.reviewedNew++;
        } else {
            m.reviewedDiscarded++;
        }
        Integer took = minutesBetween(capturedAt, c.Reviewed_At__c);
        if (took != null) {
            m.reviewMinutesSum += took;
            m.reviewMinutesCount++;
        }
    }

    private static void finish(EventMetrics m) {
        m.autoRate = pct(m.autoCount, m.processed);
        m.reviewRate = pct(m.sentToReview, m.processed);
        m.recommendationAcceptedRate = pct(m.recommendationAccepted, m.reviewedMatched);
        m.avgTopScore = m.topScoreCount == 0 ? null : (m.topScoreSum / m.topScoreCount).setScale(0);
        m.avgReviewMinutes = m.reviewMinutesCount == 0 ? null : (m.reviewMinutesSum / m.reviewMinutesCount).intValue();
    }

    private static Integer minutesBetween(Datetime fromTime, Datetime toTime) {
        if (fromTime == null || toTime == null || toTime < fromTime) {
            return null;
        }
        return ((toTime.getTime() - fromTime.getTime()) / 60000).intValue();
    }
}
