/**
 * Review console (data steward): side-by-side candidate comparison and the
 * Match / Create new HCP / Discard actions on a Capture__c record page.
 */
public with sharing class CaptureReviewController {
    public class ReviewData {
        @AuraEnabled
        public Capture__c capture;
        @AuraEnabled
        public List<Candidate> candidates;
        @AuraEnabled
        public String recommendation;
        @AuraEnabled
        public List<String> suggestionDetails;
        @AuraEnabled
        public String confidence;
        @AuraEnabled
        public Boolean canReview;
        @AuraEnabled
        public String matchedContactName;
        @AuraEnabled
        public String consentName;
        @AuraEnabled
        public List<String> tasks;
    }

    public class Candidate {
        @AuraEnabled
        public String contactId;
        @AuraEnabled
        public String fullName;
        @AuraEnabled
        public String email;
        @AuraEnabled
        public String specialty;
        @AuraEnabled
        public String city;
        @AuraEnabled
        public String organisation;
        @AuraEnabled
        public String registrationNumber;
        @AuraEnabled
        public String oneKeyId;
        @AuraEnabled
        public Integer score;
        @AuraEnabled
        public Boolean recommended;
        @AuraEnabled
        public String nameMatch;
        @AuraEnabled
        public String emailMatch;
        @AuraEnabled
        public String specialtyMatch;
        @AuraEnabled
        public String cityMatch;
        @AuraEnabled
        public String organisationMatch;
        @AuraEnabled
        public String regMatch;
    }

    private static Boolean isSteward() {
        return FeatureManagement.checkPermission(CaptureConstants.PERM_STEWARD);
    }

    private static void checkSteward() {
        if (!isSteward()) {
            throw new AuraHandledException('Only data stewards can resolve captures (permission set HCP Consent - Data Steward).');
        }
    }

    @AuraEnabled
    public static ReviewData getReviewData(Id captureId) {
        Capture__c c = [
            SELECT
                Id,
                Name,
                First_Name__c,
                Last_Name__c,
                Email__c,
                Specialty__c,
                City__c,
                Organisation__c,
                Registration_Number__c,
                Channel__c,
                Event__c,
                Event__r.Name,
                Event__r.Short_Name__c,
                Captured_By_Name__c,
                Captured_At__c,
                Consent_Method__c,
                Opt_In_Status__c,
                Notes__c,
                Interest__c,
                Processing_Stage__c,
                Matching_Status__c,
                Match_Rule__c,
                Matched_Contact__c,
                Matched_By__c,
                Consent__c,
                Suggestion__c,
                Suggestion_Confidence__c,
                Processing_Error__c,
                Signature_Captured__c
            FROM Capture__c
            WHERE Id = :captureId
        ];
        ReviewData d = new ReviewData();
        d.capture = c;
        d.canReview = isSteward() && c.Matching_Status__c == CaptureConstants.MATCH_REVIEW;
        d.confidence = c.Suggestion_Confidence__c;
        d.suggestionDetails = new List<String>();
        if (String.isNotBlank(c.Suggestion__c)) {
            List<String> lines = c.Suggestion__c.split('\n');
            d.recommendation = lines[0];
            for (Integer i = 1; i < lines.size(); i++) {
                d.suggestionDetails.add(lines[i].removeStart('- '));
            }
        }
        d.candidates = new List<Candidate>();
        for (Capture_Candidate__c cc : [
            SELECT
                Contact__c,
                Contact__r.FirstName,
                Contact__r.LastName,
                Contact__r.Email,
                Contact__r.Specialty__c,
                Contact__r.MailingCity,
                Contact__r.Account.Name,
                Contact__r.Registration_Number__c,
                Contact__r.OneKey_Id__c,
                Score__c,
                Recommended__c,
                Name_Match__c,
                Email_Match__c,
                Specialty_Match__c,
                City_Match__c,
                Organisation_Match__c,
                Reg_Number_Match__c
            FROM Capture_Candidate__c
            WHERE Capture__c = :captureId AND Contact__c != NULL
            ORDER BY Rank__c ASC
        ]) {
            Candidate x = new Candidate();
            x.contactId = cc.Contact__c;
            x.fullName = (cc.Contact__r.FirstName == null ? '' : cc.Contact__r.FirstName + ' ') + cc.Contact__r.LastName;
            x.email = cc.Contact__r.Email;
            x.specialty = cc.Contact__r.Specialty__c;
            x.city = cc.Contact__r.MailingCity;
            x.organisation = cc.Contact__r.Account == null ? null : cc.Contact__r.Account.Name;
            x.registrationNumber = cc.Contact__r.Registration_Number__c;
            x.oneKeyId = cc.Contact__r.OneKey_Id__c;
            x.score = cc.Score__c == null ? 0 : cc.Score__c.intValue();
            x.recommended = cc.Recommended__c;
            x.nameMatch = cc.Name_Match__c;
            x.emailMatch = cc.Email_Match__c;
            x.specialtyMatch = cc.Specialty_Match__c;
            x.cityMatch = cc.City_Match__c;
            x.organisationMatch = cc.Organisation_Match__c;
            x.regMatch = cc.Reg_Number_Match__c;
            d.candidates.add(x);
        }
        if (c.Matched_Contact__c != null) {
            Contact m = [SELECT Name FROM Contact WHERE Id = :c.Matched_Contact__c];
            d.matchedContactName = m.Name;
        }
        if (c.Consent__c != null) {
            d.consentName = [SELECT Name FROM Consent__c WHERE Id = :c.Consent__c].Name;
        }
        d.tasks = new List<String>();
        for (Task t : [SELECT Subject, ActivityDate FROM Task WHERE WhatId = :captureId ORDER BY CreatedDate]) {
            d.tasks.add(t.Subject + (t.ActivityDate == null ? '' : ' (due ' + t.ActivityDate.format() + ')'));
        }
        return d;
    }

    @AuraEnabled
    public static void matchToContact(Id captureId, Id contactId) {
        checkSteward();
        Capture__c c = lockForReview(captureId);
        if (contactId == null || contactId.getSobjectType() != Contact.SObjectType) {
            throw new AuraHandledException('Select a candidate HCP.');
        }
        c.Matched_Contact__c = contactId;
        c.Matching_Status__c = CaptureConstants.MATCH_REVIEWED;
        c.Match_Rule__c = 'Manual review';
        c.Matched_By__c = 'Data steward - ' + UserInfo.getName() + ' (manual review)';
        stampReview(c);
        CaptureResolutionService.complete(new List<Capture__c>{ c });
    }

    @AuraEnabled
    public static void createNewHcp(Id captureId) {
        checkSteward();
        Capture__c c = lockForReview(captureId);
        c.Matching_Status__c = CaptureConstants.MATCH_REVIEWED_NEW;
        c.Match_Rule__c = 'Manual review - new HCP';
        c.Matched_By__c = 'Data steward - ' + UserInfo.getName() + ' (new HCP created)';
        stampReview(c);
        List<Capture__c> caps = new List<Capture__c>{ c };
        CaptureResolutionService.createContactsFor(caps);
        CaptureResolutionService.complete(caps);
    }

    @AuraEnabled
    public static void discard(Id captureId) {
        checkSteward();
        Capture__c c = lockForReview(captureId);
        update new Capture__c(
            Id = c.Id,
            Matching_Status__c = CaptureConstants.MATCH_DISCARDED,
            Processing_Stage__c = CaptureConstants.STAGE_DISCARDED,
            Reviewed_By__c = UserInfo.getUserId(),
            Reviewed_At__c = System.now()
        );
    }

    /** Re-runs automatic matching for a capture in Error (or still Queued). */
    @AuraEnabled
    public static void rerunMatching(Id captureId) {
        checkSteward();
        Capture__c c = [SELECT Id, Matching_Status__c FROM Capture__c WHERE Id = :captureId];
        if (c.Matching_Status__c != CaptureConstants.MATCH_ERROR && c.Matching_Status__c != CaptureConstants.MATCH_QUEUED) {
            throw new AuraHandledException('Matching can only be re-run for captures in Error or Queued.');
        }
        update new Capture__c(
            Id = c.Id,
            Matching_Status__c = CaptureConstants.MATCH_QUEUED,
            Processing_Stage__c = CaptureConstants.STAGE_RECEIVED,
            Processing_Error__c = null
        );
        CaptureMatchingService.processCaptures(new Set<Id>{ c.Id });
    }

    private static Capture__c lockForReview(Id captureId) {
        List<Capture__c> rows = CaptureResolutionService.loadCaptures(new Set<Id>{ captureId });
        if (rows.isEmpty()) {
            throw new AuraHandledException('Capture not found.');
        }
        if (rows[0].Matching_Status__c != CaptureConstants.MATCH_REVIEW) {
            throw new AuraHandledException('This capture is not waiting for review (status: ' + rows[0].Matching_Status__c + ').');
        }
        return rows[0];
    }

    private static void stampReview(Capture__c c) {
        update new Capture__c(Id = c.Id, Reviewed_By__c = UserInfo.getUserId(), Reviewed_At__c = System.now());
    }
}
