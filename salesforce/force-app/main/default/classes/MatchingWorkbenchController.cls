/**
 * Apex behind the "Matching" workbench (data stewards): hospital filter options and the review queue.
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
}
