@IsTest
private class ConsentRecordControllerTest {
    @TestSetup
    static void setup() {
        ConsentTestFactory.settings();
        Event__c e = ConsentTestFactory.event();
        CaptureTriggerHandler.publishEnabled = false;
        Capture__c c = ConsentTestFactory.capture(e, 'Elena', 'Greco', 'elena.greco@asst-example.it', 'Paediatrics', 'Milan');
        c.Opt_In_Status__c = CaptureConstants.OPTIN_CONFIRMED;
        c.Opt_In_Confirmed_At__c = System.now();
        Capture__c rep = ConsentTestFactory.capture(e, 'Silvia', 'Marchetti', 'silvia.marchetti@gmail.com', 'Paediatrics', 'Brescia');
        rep.Channel__c = CaptureConstants.CHANNEL_REP;
        rep.Captured_By_Name__c = 'Anna Colombo';
        insert new List<Capture__c>{ c, rep };
        CaptureMatchingService.processCaptures(new Set<Id>{ c.Id, rep.Id });
        insert new Task(Subject = 'Call back', WhatId = c.Id, ActivityDate = Date.today().addDays(10), Status = 'Not Started', Priority = 'Normal');
    }

    private static Consent__c confirmedConsent() {
        return [SELECT Id, Contact__c FROM Consent__c WHERE Status__c = :CaptureConstants.CONSENT_CONFIRMED LIMIT 1];
    }

    @IsTest
    static void timelineSyncAndWithdraw() {
        Consent__c k = confirmedConsent();
        User steward = ConsentTestFactory.user('HCP_Consent_Data_Steward');
        System.runAs(steward) {
            ConsentRecordController.Timeline t = ConsentRecordController.getTimeline(k.Id);
            Assert.isTrue(t.confirmed);
            Assert.isFalse(t.sent);
            Assert.isTrue(t.canSimulate);
            Assert.areEqual(5, t.steps.size());
            Assert.areEqual('New HCP created', t.steps[2].title);
            Assert.isNotNull(t.taskSubject);

            ConsentRecordController.EvidenceCheck check = ConsentRecordController.verifyEvidence(k.Id);
            Assert.isTrue(check.recordOk, check.message);
            Assert.isNull(check.signatureOk, 'no signature on an email double opt-in');

            ConsentRecordController.simulateGigyaSync(k.Id);
            t = ConsentRecordController.getTimeline(k.Id);
            Assert.isTrue(t.sent);
            Assert.areEqual('ok', t.steps[t.steps.size() - 1].state);

            Boolean failed = false;
            try {
                ConsentRecordController.EvidenceCheck check = ConsentRecordController.verifyEvidence(k.Id);
            Assert.isTrue(check.recordOk, check.message);
            Assert.isNull(check.signatureOk, 'no signature on an email double opt-in');

            ConsentRecordController.simulateGigyaSync(k.Id);
            } catch (AuraHandledException e) {
                failed = true;
            }
            Assert.isTrue(failed, 'already sent');

            ConsentRecordController.withdrawConsent(k.Id);
            t = ConsentRecordController.getTimeline(k.Id);
            Assert.isFalse(t.canWithdraw);
        }
        Assert.areEqual(CaptureConstants.HCP_OPTOUT, [SELECT Consent_Status__c FROM Contact WHERE Id = :k.Contact__c].Consent_Status__c);
        Assert.areEqual(1, [SELECT COUNT() FROM Capture__c WHERE Processing_Stage__c = :CaptureConstants.STAGE_SENT]);
    }

    @IsTest
    static void pendingTimelineAndPermissions() {
        Consent__c pending = [SELECT Id FROM Consent__c WHERE Status__c = :CaptureConstants.CONSENT_PENDING LIMIT 1];
        User nobody = ConsentTestFactory.user(null);
        System.runAs(nobody) {
            ConsentRecordController.Timeline t = ConsentRecordController.getTimeline(pending.Id);
            Assert.isFalse(t.confirmed);
            Assert.isFalse(t.canSimulate);
            Assert.areEqual('wait', t.steps[1].state);
            Boolean failed = false;
            try {
                ConsentRecordController.withdrawConsent(pending.Id);
            } catch (AuraHandledException e) {
                failed = true;
            }
            Assert.isTrue(failed);
        }
    }

    @IsTest
    static void dashboardStats() {
        Event__c e = [SELECT Id FROM Event__c LIMIT 1];
        CaptureDashboardController.Stats all = CaptureDashboardController.getStats(null);
        Assert.areEqual(2, all.total);
        CaptureDashboardController.Stats one = CaptureDashboardController.getStats(e.Id);
        Assert.areEqual(2, one.total);
        Integer rep = 0;
        for (CaptureDashboardController.Bucket b : one.byChannel) {
            if (b.label == CaptureConstants.CHANNEL_REP) {
                rep = b.value;
            }
        }
        Assert.areEqual(1, rep);
        Assert.areEqual(1, one.byRep.size());
        Assert.areEqual('Anna Colombo', one.byRep[0].label);
        Assert.areEqual(1, CaptureDashboardController.getEvents().size());
        Integer confirmed = 0;
        for (CaptureDashboardController.Bucket b : one.consent) {
            if (b.label == 'Confirmed') {
                confirmed = b.value;
            }
        }
        Assert.areEqual(1, confirmed);
    }
}
