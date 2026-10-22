/**
 * Apex behind the "Matching" workbench (data stewards):
 * review queue, duplicate HCP pairs, side-by-side comparison, merge and "not a duplicate".
 * without sharing: stewards work on HCPs and captures they do not own; every method checks the
 * HCP_Capture_Data_Steward custom permission.
 */
public without sharing class MatchingWorkbenchController {
    public class Option {
        @AuraEnabled
        public String value;
        @AuraEnabled
        public String label;
        @AuraEnabled
        public String parent;
    }

    public class QueueRow {
        @AuraEnabled
        public String id;
        @AuraEnabled
        public String name;
        @AuraEnabled
        public String fullName;
        @AuraEnabled
        public String email;
        @AuraEnabled
        public String specialty;
        @AuraEnabled
        public String city;
        @AuraEnabled
        public String hospital;
        @AuraEnabled
        public String eventName;
        @AuraEnabled
        public String capturedAt;
        @AuraEnabled
        public String confidence;
        @AuraEnabled
        public Integer candidates;
        @AuraEnabled
        public String topCandidate;
        @AuraEnabled
        public Integer topScore;
        @AuraEnabled
        public String rule;
    }

    public class PairRow {
        @AuraEnabled
        public String id;
        @AuraEnabled
        public String name;
        @AuraEnabled
        public String contactA;
        @AuraEnabled
        public String nameA;
        @AuraEnabled
        public String contactB;
        @AuraEnabled
        public String nameB;
        @AuraEnabled
        public Integer score;
        @AuraEnabled
        public String hospitals;
        @AuraEnabled
        public String departments;
        @AuraEnabled
        public String status;
        @AuraEnabled
        public String summary;
    }

    public class FieldRow {
        @AuraEnabled
        public String field;
        @AuraEnabled
        public String label;
        @AuraEnabled
        public String valueA;
        @AuraEnabled
        public String valueB;
        @AuraEnabled
        public Boolean same;
    }

    public class PairDetail {
        @AuraEnabled
        public PairRow pair;
        @AuraEnabled
        public List<FieldRow> fields;
        @AuraEnabled
        public List<String> explanation;
        @AuraEnabled
        public String relatedA;
        @AuraEnabled
        public String relatedB;
        @AuraEnabled
        public String affiliationsA;
        @AuraEnabled
        public String affiliationsB;
        @AuraEnabled
        public String consentA;
        @AuraEnabled
        public String consentB;
        @AuraEnabled
        public String suggestedMaster;
        @AuraEnabled
        public String suggestionReason;
    }

    public class MergeRow {
        @AuraEnabled
        public String id;
        @AuraEnabled
        public String name;
        @AuraEnabled
        public String survivorId;
        @AuraEnabled
        public String survivorName;
        @AuraEnabled
        public String mergedName;
        @AuraEnabled
        public String mergedId;
        @AuraEnabled
        public String mergedBy;
        @AuraEnabled
        public String mergedAt;
        @AuraEnabled
        public String summary;
    }

    private static void checkSteward() {
        if (!FeatureManagement.checkPermission(CaptureConstants.PERM_STEWARD)) {
            throw new AuraHandledException('Only data stewards can use the Matching workbench (permission set HCP Consent - Data Steward).');
        }
    }

    // ------------------------------------------------------------ filters

    /** Hospitals (parent = '') and their departments (parent = hospital Id). */
    @AuraEnabled
    public static List<Option> getHcoOptions() {
        checkSteward();
        List<Option> out = new List<Option>();
        HcoDirectory dir = HcoDirectory.get();
        for (Account h : dir.hospitals.values()) {
            out.add(option(h.Id, h.Name + (String.isBlank(h.BillingCity) ? '' : ' (' + h.BillingCity + ')'), ''));
            List<Account> depts = dir.departmentsByHospital.get(h.Id);
            if (depts != null) {
                for (Account d : depts) {
                    out.add(option(d.Id, String.isBlank(d.Department_Type__c) ? d.Name : d.Department_Type__c, h.Id));
                }
            }
        }
        return out;
    }

    private static Option option(String value, String label, String parent) {
        Option o = new Option();
        o.value = value;
        o.label = label;
        o.parent = parent;
        return o;
    }

    // ------------------------------------------------------------ review queue

    @AuraEnabled
    public static List<QueueRow> getReviewQueue(String hospitalId, String confidence) {
        checkSteward();
        String status = CaptureConstants.MATCH_REVIEW;
        String q =
            'SELECT Id, Name, First_Name__c, Last_Name__c, Email__c, Specialty__c, City__c, Organisation__c, Hospital__r.Name, ' +
            'Event__r.Short_Name__c, Event__r.Name, Captured_At__c, Suggestion_Confidence__c, Candidate_Count__c, Match_Rule__c ' +
            'FROM Capture__c WHERE Matching_Status__c = :status';
        Id hosp = String.isBlank(hospitalId) ? null : Id.valueOf(hospitalId);
        if (hosp != null) {
            q += ' AND Hospital__c = :hosp';
        }
        if (String.isNotBlank(confidence)) {
            q += ' AND Suggestion_Confidence__c = :confidence';
        }
        q += ' ORDER BY Captured_At__c ASC LIMIT 200';
        List<Capture__c> caps = Database.query(q);
        Map<Id, Capture_Candidate__c> top = new Map<Id, Capture_Candidate__c>();
        for (Capture_Candidate__c cc : [
            SELECT Capture__c, Score__c, Contact__r.FirstName, Contact__r.LastName, Contact__r.MailingCity
            FROM Capture_Candidate__c
            WHERE Capture__c IN :caps AND Recommended__c = TRUE
        ]) {
            top.put(cc.Capture__c, cc);
        }
        List<QueueRow> out = new List<QueueRow>();
        for (Capture__c c : caps) {
            QueueRow r = new QueueRow();
            r.id = c.Id;
            r.name = c.Name;
            r.fullName = ((c.First_Name__c == null ? '' : c.First_Name__c + ' ') + (c.Last_Name__c == null ? '' : c.Last_Name__c)).trim();
            r.email = c.Email__c;
            r.specialty = c.Specialty__c;
            r.city = c.City__c;
            r.hospital = c.Hospital__r != null ? c.Hospital__r.Name : c.Organisation__c;
            r.eventName = c.Event__r == null ? null : (String.isBlank(c.Event__r.Short_Name__c) ? c.Event__r.Name : c.Event__r.Short_Name__c);
            r.capturedAt = c.Captured_At__c == null ? null : c.Captured_At__c.format('d MMM HH:mm');
            r.confidence = c.Suggestion_Confidence__c;
            r.candidates = c.Candidate_Count__c == null ? 0 : c.Candidate_Count__c.intValue();
            r.rule = c.Match_Rule__c;
            Capture_Candidate__c t = top.get(c.Id);
            if (t != null) {
                r.topCandidate = ((t.Contact__r.FirstName == null ? '' : t.Contact__r.FirstName + ' ') + t.Contact__r.LastName) +
                    (t.Contact__r.MailingCity == null ? '' : ' (' + t.Contact__r.MailingCity + ')');
                r.topScore = t.Score__c == null ? 0 : t.Score__c.intValue();
            }
            out.add(r);
        }
        return out;
    }

    // ------------------------------------------------------------ duplicate pairs

    @AuraEnabled
    public static List<PairRow> getPairs(String status, String hospitalId, String departmentId, Integer minScore) {
        checkSteward();
        String st = String.isBlank(status) ? DuplicateScanJob.STATUS_OPEN : status;
        Integer minValue = minScore == null ? 0 : minScore;
        String q =
            'SELECT Id, Name, Contact_A__c, Contact_A__r.Name, Contact_B__c, Contact_B__r.Name, Score__c, Hospital_Names__c, ' +
            'Department_Names__c, Status__c, Name_Match__c, Email_Match__c, Reg_Number_Match__c, Organisation_Match__c ' +
            'FROM HCP_Duplicate_Pair__c WHERE Status__c = :st AND Score__c >= :minValue';
        if (st == DuplicateScanJob.STATUS_OPEN) {
            q += ' AND Contact_A__c != NULL AND Contact_B__c != NULL';
        }
        String hLike;
        String dLike;
        if (String.isNotBlank(departmentId)) {
            dLike = '%' + String.valueOf(Id.valueOf(departmentId)) + '%';
            q += ' AND Department_Ids__c LIKE :dLike';
        } else if (String.isNotBlank(hospitalId)) {
            hLike = '%' + String.valueOf(Id.valueOf(hospitalId)) + '%';
            q += ' AND Hospital_Ids__c LIKE :hLike';
        }
        q += ' ORDER BY Score__c DESC, Name ASC LIMIT 200';
        List<PairRow> out = new List<PairRow>();
        for (HCP_Duplicate_Pair__c p : Database.query(q)) {
            out.add(toRow(p));
        }
        return out;
    }

    private static PairRow toRow(HCP_Duplicate_Pair__c p) {
        PairRow r = new PairRow();
        r.id = p.Id;
        r.name = p.Name;
        r.contactA = p.Contact_A__c;
        r.nameA = p.Contact_A__r == null ? '(merged)' : p.Contact_A__r.Name;
        r.contactB = p.Contact_B__c;
        r.nameB = p.Contact_B__r == null ? '(merged)' : p.Contact_B__r.Name;
        r.score = p.Score__c == null ? 0 : p.Score__c.intValue();
        r.hospitals = p.Hospital_Names__c;
        r.departments = p.Department_Names__c;
        r.status = p.Status__c;
        List<String> s = new List<String>();
        s.add('name ' + label(p.Name_Match__c));
        s.add('email ' + label(p.Email_Match__c));
        s.add('reg. no ' + label(p.Reg_Number_Match__c));
        s.add('hospital ' + label(p.Organisation_Match__c));
        r.summary = String.join(s, ' · ');
        return r;
    }

    private static String label(String flag) {
        if (flag == CaptureConstants.FLAG_EXACT) {
            return '✓';
        }
        if (flag == CaptureConstants.FLAG_PARTIAL) {
            return '≈';
        }
        if (flag == CaptureConstants.FLAG_NA) {
            return '–';
        }
        return '✗';
    }

    @AuraEnabled
    public static PairDetail getPairDetail(Id pairId) {
        checkSteward();
        HCP_Duplicate_Pair__c p = [
            SELECT Id, Name, Contact_A__c, Contact_A__r.Name, Contact_B__c, Contact_B__r.Name, Score__c, Hospital_Names__c, Department_Names__c,
                Status__c, Name_Match__c, Email_Match__c, Reg_Number_Match__c, Organisation_Match__c, Score_Explanation__c
            FROM HCP_Duplicate_Pair__c
            WHERE Id = :pairId
        ];
        if (p.Contact_A__c == null || p.Contact_B__c == null) {
            throw new AuraHandledException('One of the two HCPs no longer exists.');
        }
        PairDetail d = new PairDetail();
        d.pair = toRow(p);
        d.explanation = String.isBlank(p.Score_Explanation__c) ? new List<String>() : p.Score_Explanation__c.split('\n');
        Contact a = HcpMergeService.load(p.Contact_A__c);
        Contact b = HcpMergeService.load(p.Contact_B__c);
        Map<String, Schema.SObjectField> fm = Schema.SObjectType.Contact.fields.getMap();
        d.fields = new List<FieldRow>();
        for (String f : HcpMergeService.MERGE_FIELDS) {
            FieldRow r = new FieldRow();
            r.field = f;
            r.label = fm.get(f).getDescribe().getLabel();
            r.valueA = display(a, f);
            r.valueB = display(b, f);
            r.same = r.valueA == r.valueB;
            d.fields.add(r);
        }
        Map<Id, String> aff = CaptureReviewController.affiliationLabels(new Set<Id>{ a.Id, b.Id });
        d.affiliationsA = aff.get(a.Id);
        d.affiliationsB = aff.get(b.Id);
        d.consentA = a.Consent_Status__c;
        d.consentB = b.Consent_Status__c;
        Integer relA = relatedCount(a.Id);
        Integer relB = relatedCount(b.Id);
        d.relatedA = relatedText(a.Id);
        d.relatedB = relatedText(b.Id);
        // keep the record with more history (consents, captures, ...), else the older one
        if (relA != relB) {
            d.suggestedMaster = relA > relB ? a.Id : b.Id;
            d.suggestionReason = 'keeps the record with more related records';
        } else {
            d.suggestedMaster = a.CreatedDate <= b.CreatedDate ? a.Id : b.Id;
            d.suggestionReason = 'keeps the older record';
        }
        return d;
    }

    private static String display(Contact c, String f) {
        Object v = c.get(f);
        if (v == null) {
            return null;
        }
        if (f == 'AccountId') {
            String l = HcoDirectory.get().label((Id) v);
            if (l == null) {
                Id accountId = (Id) v;
                List<Account> acc = [SELECT Name FROM Account WHERE Id = :accountId];
                l = acc.isEmpty() ? String.valueOf(v) : acc[0].Name;
            }
            return l;
        }
        return String.valueOf(v);
    }

    private static Integer relatedCount(Id contactId) {
        return [SELECT COUNT() FROM Consent__c WHERE Contact__c = :contactId] +
            [SELECT COUNT() FROM Capture__c WHERE Matched_Contact__c = :contactId] +
            [SELECT COUNT() FROM Event_Attendee__c WHERE Contact__c = :contactId];
    }

    private static String relatedText(Id contactId) {
        return [SELECT COUNT() FROM Consent__c WHERE Contact__c = :contactId] + ' consents · ' +
            [SELECT COUNT() FROM Capture__c WHERE Matched_Contact__c = :contactId] + ' captures · ' +
            [SELECT COUNT() FROM Event_Attendee__c WHERE Contact__c = :contactId] + ' event attendances · ' +
            [SELECT COUNT() FROM HCP_Affiliation__c WHERE Contact__c = :contactId] + ' affiliations';
    }

    /** Merges the other HCP of the pair into masterId. choices: field -> 'master' | 'duplicate'. Returns the merge record Id. */
    @AuraEnabled
    public static String mergePair(Id pairId, Id masterId, Map<String, String> choices) {
        checkSteward();
        HCP_Duplicate_Pair__c p = [SELECT Id, Contact_A__c, Contact_B__c, Status__c FROM HCP_Duplicate_Pair__c WHERE Id = :pairId];
        if (p.Status__c != DuplicateScanJob.STATUS_OPEN) {
            throw new AuraHandledException('This pair is already decided (' + p.Status__c + ').');
        }
        if (masterId != p.Contact_A__c && masterId != p.Contact_B__c) {
            throw new AuraHandledException('The surviving HCP must be one of the pair.');
        }
        Id dupId = masterId == p.Contact_A__c ? p.Contact_B__c : p.Contact_A__c;
        try {
            return HcpMergeService.mergeHcps(masterId, dupId, choices, pairId).Id;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static void markNotDuplicate(Id pairId, String note) {
        checkSteward();
        HCP_Duplicate_Pair__c p = [SELECT Id, Status__c FROM HCP_Duplicate_Pair__c WHERE Id = :pairId];
        if (p.Status__c != DuplicateScanJob.STATUS_OPEN) {
            throw new AuraHandledException('This pair is already decided (' + p.Status__c + ').');
        }
        update new HCP_Duplicate_Pair__c(
            Id = pairId,
            Status__c = DuplicateScanJob.STATUS_NOT_DUPLICATE,
            Decided_By__c = UserInfo.getUserId(),
            Decided_At__c = System.now(),
            Decision_Note__c = String.isBlank(note) ? null : note.left(255)
        );
    }

    /** Re-opens a "Not a duplicate" decision made by mistake. */
    @AuraEnabled
    public static void reopenPair(Id pairId) {
        checkSteward();
        HCP_Duplicate_Pair__c p = [SELECT Id, Status__c FROM HCP_Duplicate_Pair__c WHERE Id = :pairId];
        if (p.Status__c != DuplicateScanJob.STATUS_NOT_DUPLICATE) {
            throw new AuraHandledException('Only "Not a duplicate" decisions can be re-opened.');
        }
        update new HCP_Duplicate_Pair__c(Id = pairId, Status__c = DuplicateScanJob.STATUS_OPEN, Decided_By__c = null, Decided_At__c = null);
    }

    @AuraEnabled
    public static String runDuplicateScan() {
        checkSteward();
        return DuplicateScanJob.run();
    }

    @AuraEnabled
    public static String getJobStatus(String jobId) {
        checkSteward();
        if (String.isBlank(jobId)) {
            return null;
        }
        List<AsyncApexJob> jobs = [SELECT Status, JobItemsProcessed, TotalJobItems, NumberOfErrors FROM AsyncApexJob WHERE Id = :jobId];
        if (jobs.isEmpty()) {
            return null;
        }
        AsyncApexJob j = jobs[0];
        return j.Status + ' (' + j.JobItemsProcessed + '/' + j.TotalJobItems + ')' + (j.NumberOfErrors > 0 ? ' - ' + j.NumberOfErrors + ' errors' : '');
    }

    // ------------------------------------------------------------ merge history

    @AuraEnabled
    public static List<MergeRow> getMerges() {
        checkSteward();
        List<MergeRow> out = new List<MergeRow>();
        for (HCP_Merge__c m : [
            SELECT Id, Name, Master_Contact__c, Master_Contact__r.Name, Master_Contact_Id__c, Merged_Contact_Name__c, Merged_Contact_Id__c,
                Merged_By__r.Name, Merged_At__c, Related_Summary__c
            FROM HCP_Merge__c
            ORDER BY Merged_At__c DESC
            LIMIT 100
        ]) {
            MergeRow r = new MergeRow();
            r.id = m.Id;
            r.name = m.Name;
            r.survivorId = m.Master_Contact__c;
            r.survivorName = m.Master_Contact__r == null ? m.Master_Contact_Id__c : m.Master_Contact__r.Name;
            r.mergedName = m.Merged_Contact_Name__c;
            r.mergedId = m.Merged_Contact_Id__c;
            r.mergedBy = m.Merged_By__r == null ? null : m.Merged_By__r.Name;
            r.mergedAt = m.Merged_At__c == null ? null : m.Merged_At__c.format('d MMM yyyy HH:mm');
            r.summary = m.Related_Summary__c;
            out.add(r);
        }
        return out;
    }
}
