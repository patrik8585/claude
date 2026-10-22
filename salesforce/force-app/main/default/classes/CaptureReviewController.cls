/**
 * Review console (data steward): side-by-side candidate comparison and the
 * Match / Create new HCP / Discard actions on a Capture__c record page.
 * without sharing: stewards resolve captures they do not own. Access is limited to the
 * HCP Consent Data Steward / Admin permission sets (class access) and every write checks
 * the HCP_Capture_Data_Steward custom permission.
 */
public without sharing class CaptureReviewController {
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
        /** Active affiliations, e.g. "Paediatrics - Gaslini Institute (primary)". */
        @AuraEnabled
        public String affiliations;
        /** One line per scoring rule that fired. */
        @AuraEnabled
        public List<String> explanation;
    }

    public class BulkResult {
        @AuraEnabled
        public Integer processed;
        @AuraEnabled
        public Integer skipped;
        @AuraEnabled
        public String message;
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
                Hospital__c,
                Hospital__r.Name,
                Department__c,
                Department__r.Name,
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
                Reg_Number_Match__c,
                Score_Explanation__c
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
            x.explanation = String.isBlank(cc.Score_Explanation__c) ? new List<String>() : cc.Score_Explanation__c.split('\n');
            d.candidates.add(x);
        }
        Map<Id, String> aff = affiliationLabels(candidateContactIds(d.candidates));
        for (Candidate x : d.candidates) {
            x.affiliations = aff.get(x.contactId);
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
        if (c.Channel__c == CaptureConstants.CHANNEL_REGISTRATION) {
            throw new AuraHandledException('A registration can only be matched to an HCP already in Salesforce: match it or discard it.');
        }
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

    private static Set<Id> candidateContactIds(List<Candidate> candidates) {
        Set<Id> ids = new Set<Id>();
        for (Candidate x : candidates) {
            ids.add(x.contactId);
        }
        return ids;
    }

    /** "Paediatrics - Gaslini Institute (primary); Neonatology - Gaslini Institute" per Contact. */
    public static Map<Id, String> affiliationLabels(Set<Id> contactIds) {
        Map<Id, List<String>> parts = new Map<Id, List<String>>();
        HcoDirectory dir = HcoDirectory.get();
        for (HCP_Affiliation__c a : [
            SELECT Contact__c, HCO__c, HCO__r.Name, Primary__c, Role__c
            FROM HCP_Affiliation__c
            WHERE Contact__c IN :contactIds AND Active__c = TRUE
            ORDER BY Primary__c DESC, CreatedDate ASC
        ]) {
            if (!parts.containsKey(a.Contact__c)) {
                parts.put(a.Contact__c, new List<String>());
            }
            String label = dir.label(a.HCO__c);
            parts.get(a.Contact__c).add((label == null ? a.HCO__r.Name : label) + (a.Primary__c ? ' (primary)' : ''));
        }
        Map<Id, String> out = new Map<Id, String>();
        for (Id cid : parts.keySet()) {
            out.put(cid, String.join(parts.get(cid), '; '));
        }
        return out;
    }

    /**
     * Bulk actions from the Matching workbench.
     * action: 'recommended' (match each capture to its recommended candidate) | 'new' (create new HCPs) | 'discard'.
     * Captures no longer waiting for review are skipped.
     */
    @AuraEnabled
    public static BulkResult bulkResolve(List<Id> captureIds, String action) {
        checkSteward();
        if (captureIds == null || captureIds.isEmpty()) {
            throw new AuraHandledException('Select at least one capture.');
        }
        if (captureIds.size() > 50) {
            throw new AuraHandledException('Select at most 50 captures at a time.');
        }
        List<Capture__c> open = new List<Capture__c>();
        for (Capture__c c : CaptureResolutionService.loadCaptures(new Set<Id>(captureIds))) {
            if (c.Matching_Status__c == CaptureConstants.MATCH_REVIEW) {
                open.add(c);
            }
        }
        BulkResult r = new BulkResult();
        r.skipped = captureIds.size() - open.size();
        r.processed = 0;
        if (open.isEmpty()) {
            r.message = 'Nothing to do: the selected captures are no longer waiting for review.';
            return r;
        }
        Datetime now = System.now();
        List<Capture__c> stamps = new List<Capture__c>();
        if (action == 'recommended') {
            Map<Id, Id> recommended = new Map<Id, Id>();
            for (Capture_Candidate__c cc : [
                SELECT Capture__c, Contact__c
                FROM Capture_Candidate__c
                WHERE Capture__c IN :open AND Recommended__c = TRUE AND Contact__c != NULL
            ]) {
                recommended.put(cc.Capture__c, cc.Contact__c);
            }
            List<Capture__c> matched = new List<Capture__c>();
            for (Capture__c c : open) {
                Id contactId = recommended.get(c.Id);
                if (contactId == null) {
                    r.skipped++;
                    continue;
                }
                c.Matched_Contact__c = contactId;
                c.Matching_Status__c = CaptureConstants.MATCH_REVIEWED;
                c.Match_Rule__c = 'Manual review (bulk - recommended candidate)';
                c.Matched_By__c = 'Data steward - ' + UserInfo.getName() + ' (bulk review, recommended candidate)';
                matched.add(c);
                stamps.add(new Capture__c(Id = c.Id, Reviewed_By__c = UserInfo.getUserId(), Reviewed_At__c = now));
            }
            update stamps;
            if (!matched.isEmpty()) {
                CaptureResolutionService.complete(matched);
            }
            r.processed = matched.size();
        } else if (action == 'new') {
            // registrations are never turned into new HCPs
            List<Capture__c> walkIns = new List<Capture__c>();
            for (Capture__c c : open) {
                if (c.Channel__c == CaptureConstants.CHANNEL_REGISTRATION) {
                    r.skipped++;
                } else {
                    walkIns.add(c);
                }
            }
            open = walkIns;
            for (Capture__c c : open) {
                c.Matching_Status__c = CaptureConstants.MATCH_REVIEWED_NEW;
                c.Match_Rule__c = 'Manual review - new HCP (bulk)';
                c.Matched_By__c = 'Data steward - ' + UserInfo.getName() + ' (new HCP created, bulk)';
                stamps.add(new Capture__c(Id = c.Id, Reviewed_By__c = UserInfo.getUserId(), Reviewed_At__c = now));
            }
            update stamps;
            if (!open.isEmpty()) {
                CaptureResolutionService.createContactsFor(open);
                CaptureResolutionService.complete(open);
            }
            r.processed = open.size();
        } else if (action == 'discard') {
            for (Capture__c c : open) {
                stamps.add(
                    new Capture__c(
                        Id = c.Id,
                        Matching_Status__c = CaptureConstants.MATCH_DISCARDED,
                        Processing_Stage__c = CaptureConstants.STAGE_DISCARDED,
                        Reviewed_By__c = UserInfo.getUserId(),
                        Reviewed_At__c = now
                    )
                );
            }
            update stamps;
            r.processed = open.size();
        } else {
            throw new AuraHandledException('Unknown action.');
        }
        r.message = r.processed + (r.processed == 1 ? ' capture' : ' captures') + ' resolved' + (r.skipped > 0 ? ', ' + r.skipped + ' skipped' : '') + '.';
        return r;
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
