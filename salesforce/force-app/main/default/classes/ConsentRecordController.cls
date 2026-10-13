/**
 * Consent record page: Gigya synchronisation timeline (mockup step 6),
 * demo "simulate sync" and consent withdrawal.
 * without sharing: stewards update consents they do not own; writes check the
 * HCP_Capture_Data_Steward custom permission, class access is limited by permission sets.
 */
public without sharing class ConsentRecordController {
    public class Step {
        @AuraEnabled
        public String title;
        @AuraEnabled
        public String detail;
        /** ok | wait */
        @AuraEnabled
        public String state;
        @AuraEnabled
        public String key;
    }

    public class Timeline {
        @AuraEnabled
        public String consentName;
        @AuraEnabled
        public String status;
        @AuraEnabled
        public String gigyaStatus;
        @AuraEnabled
        public Boolean sent;
        @AuraEnabled
        public Boolean confirmed;
        @AuraEnabled
        public Boolean canSimulate;
        @AuraEnabled
        public Boolean canWithdraw;
        @AuraEnabled
        public List<Step> steps;
        @AuraEnabled
        public String captureId;
        @AuraEnabled
        public String captureName;
        @AuraEnabled
        public String taskSubject;
    }

    @AuraEnabled
    public static Timeline getTimeline(Id consentId) {
        Consent__c k = [
            SELECT
                Id,
                Name,
                Status__c,
                Channel__c,
                Opt_In_Method__c,
                Captured_At__c,
                Confirmed_At__c,
                Withdrawn_At__c,
                CreatedDate,
                Matched_By__c,
                Gigya_Status__c,
                Gigya_Sent_At__c,
                Gigya_Message__c,
                Source_Capture__c,
                Source_Capture__r.Name,
                Source_Capture__r.Matching_Status__c
            FROM Consent__c
            WHERE Id = :consentId
        ];
        Boolean steward = FeatureManagement.checkPermission(CaptureConstants.PERM_STEWARD);
        Timeline t = new Timeline();
        t.consentName = k.Name;
        t.status = k.Status__c;
        t.gigyaStatus = k.Gigya_Status__c;
        t.confirmed = k.Status__c == CaptureConstants.CONSENT_CONFIRMED;
        t.sent = k.Gigya_Status__c == CaptureConstants.GIGYA_SENT;
        t.canSimulate = steward && k.Gigya_Status__c == CaptureConstants.GIGYA_QUEUED;
        t.canWithdraw = steward && k.Status__c != CaptureConstants.CONSENT_WITHDRAWN;
        t.captureId = k.Source_Capture__c;
        t.captureName = k.Source_Capture__c == null ? null : k.Source_Capture__r.Name;
        if (k.Source_Capture__c != null) {
            for (Task tk : [SELECT Subject, ActivityDate FROM Task WHERE WhatId = :k.Source_Capture__c LIMIT 1]) {
                t.taskSubject = tk.Subject + (tk.ActivityDate == null ? '' : ' - due ' + tk.ActivityDate.format());
            }
        }

        Boolean signed = k.Opt_In_Method__c == CaptureConstants.METHOD_SIGNATURE;
        Boolean legacy = k.Opt_In_Method__c == CaptureConstants.METHOD_PITCHER;
        t.steps = new List<Step>();
        t.steps.add(step('received', legacy ? 'Consent captured in Pitcher' : 'Capture received in staging', fmt(k.Captured_At__c) + (k.Channel__c == null ? '' : ' · ' + k.Channel__c), true));
        t.steps.add(
            step(
                'optin',
                signed ? 'HCP signed on the rep’s device' : 'HCP confirmed by email (double opt-in)',
                k.Confirmed_At__c != null ? fmt(k.Confirmed_At__c) : 'Waiting for the HCP to click “Confirm”',
                k.Confirmed_At__c != null
            )
        );
        if (!legacy) {
            Boolean isNew = k.Source_Capture__c != null &&
                (k.Source_Capture__r.Matching_Status__c == CaptureConstants.MATCH_NEW ||
                k.Source_Capture__r.Matching_Status__c == CaptureConstants.MATCH_REVIEWED_NEW);
            t.steps.add(step('match', isNew ? 'New HCP created' : 'Matched to existing HCP', k.Matched_By__c == null ? '' : k.Matched_By__c, true));
        }
        t.steps.add(step('created', 'Consent record created', fmt(k.CreatedDate) + ' · ' + k.Name, true));
        if (k.Status__c == CaptureConstants.CONSENT_WITHDRAWN) {
            t.steps.add(step('withdrawn', 'Consent withdrawn', fmt(k.Withdrawn_At__c), true));
        }
        String gigyaDetail;
        if (t.sent) {
            gigyaDetail = fmt(k.Gigya_Sent_At__c) + ' · via existing integration';
        } else if (k.Gigya_Status__c == CaptureConstants.GIGYA_QUEUED) {
            gigyaDetail = 'Queued - the existing integration picks it up';
        } else if (k.Gigya_Status__c == CaptureConstants.GIGYA_ERROR) {
            gigyaDetail = 'Error: ' + (k.Gigya_Message__c == null ? 'see integration log' : k.Gigya_Message__c);
        } else {
            gigyaDetail = 'Sent automatically once consent is confirmed';
        }
        t.steps.add(step('gigya', 'Sent to Gigya', gigyaDetail, t.sent));
        return t;
    }

    /** Demo only: stands in for the existing Gigya integration marking the record as sent. */
    @AuraEnabled
    public static void simulateGigyaSync(Id consentId) {
        checkSteward();
        Consent__c k = [SELECT Id, Gigya_Status__c, Source_Capture__c FROM Consent__c WHERE Id = :consentId];
        if (k.Gigya_Status__c != CaptureConstants.GIGYA_QUEUED) {
            throw new AuraHandledException('Only queued consents can be synchronised.');
        }
        markSent(new List<Consent__c>{ k });
    }

    public static void markSent(List<Consent__c> consents) {
        Datetime now = System.now();
        Set<Id> captureIds = new Set<Id>();
        for (Consent__c k : consents) {
            k.Gigya_Status__c = CaptureConstants.GIGYA_SENT;
            k.Gigya_Sent_At__c = now;
            k.Gigya_Message__c = 'Simulated sync (demo)';
            if (k.Source_Capture__c != null) {
                captureIds.add(k.Source_Capture__c);
            }
        }
        update consents;
        List<Capture__c> caps = new List<Capture__c>();
        for (Id cid : captureIds) {
            caps.add(new Capture__c(Id = cid, Processing_Stage__c = CaptureConstants.STAGE_SENT));
        }
        update caps;
    }

    @AuraEnabled
    public static void withdrawConsent(Id consentId) {
        checkSteward();
        Consent__c k = [SELECT Id, Contact__c, Status__c FROM Consent__c WHERE Id = :consentId];
        k.Status__c = CaptureConstants.CONSENT_WITHDRAWN;
        k.Withdrawn_At__c = System.now();
        // the existing integration forwards the withdrawal to Gigya
        k.Gigya_Status__c = CaptureConstants.GIGYA_QUEUED;
        update k;
        ConsentService.refreshContactSummary(new Set<Id>{ k.Contact__c });
    }

    private static void checkSteward() {
        if (!FeatureManagement.checkPermission(CaptureConstants.PERM_STEWARD)) {
            throw new AuraHandledException('Only data stewards can change consent records.');
        }
    }

    private static Step step(String key, String title, String detail, Boolean ok) {
        Step s = new Step();
        s.key = key;
        s.title = title;
        s.detail = detail;
        s.state = ok ? 'ok' : 'wait';
        return s;
    }

    private static String fmt(Datetime d) {
        return d == null ? '' : d.format('d MMM yyyy, HH:mm');
    }
}
