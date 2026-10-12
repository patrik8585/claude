@IsTest
private class CaptureReviewControllerTest {
    @TestSetup
    static void setup() {
        ConsentTestFactory.settings();
        Event__c e = ConsentTestFactory.event();
        ConsentTestFactory.contact('Roberto', 'Esposito', 'r.esposito@santobono-example.it', 'Paediatric Gastroenterology', 'Naples', 'NA-27711');
        ConsentTestFactory.contact('Roberto', 'Esposito', 'roberto.esposito@aslroma-example.it', 'Paediatrics', 'Rome', 'RM-19904');
        CaptureTriggerHandler.publishEnabled = false;
        List<Capture__c> caps = new List<Capture__c>();
        for (Integer i = 0; i < 3; i++) {
            Capture__c c = ConsentTestFactory.capture(e, 'Roberto', 'Esposito', 'r.esposito' + i + '@gmail.com', 'Paediatric Gastroenterology', 'Naples');
            c.Opt_In_Status__c = CaptureConstants.OPTIN_CONFIRMED;
            c.Opt_In_Confirmed_At__c = System.now();
            caps.add(c);
        }
        insert caps;
        CaptureMatchingService.processCaptures(new Map<Id, Capture__c>(caps).keySet());
    }

    private static List<Capture__c> caps() {
        return [SELECT Id, Matching_Status__c FROM Capture__c ORDER BY Email__c];
    }

    @IsTest
    static void reviewDataAndActions() {
        List<Capture__c> caps = caps();
        Assert.areEqual(CaptureConstants.MATCH_REVIEW, caps[0].Matching_Status__c);
        User steward = ConsentTestFactory.user('HCP_Consent_Data_Steward');
        System.runAs(steward) {
            CaptureReviewController.ReviewData d = CaptureReviewController.getReviewData(caps[0].Id);
            Assert.isTrue(d.canReview);
            Assert.areEqual(2, d.candidates.size());
            Assert.isTrue(d.candidates[0].recommended);
            Assert.areEqual('Naples', d.candidates[0].city);
            Assert.isTrue(d.recommendation.startsWith('Recommended: Dr. Roberto Esposito'));
            Assert.areEqual(2, d.suggestionDetails.size(), String.valueOf(d.suggestionDetails));

            CaptureReviewController.matchToContact(caps[0].Id, d.candidates[0].contactId);
            CaptureReviewController.createNewHcp(caps[1].Id);
            CaptureReviewController.discard(caps[2].Id);

            Boolean failed = false;
            try {
                CaptureReviewController.discard(caps[2].Id);
            } catch (AuraHandledException e) {
                failed = true;
            }
            Assert.isTrue(failed, 'already resolved');

            CaptureReviewController.ReviewData after = CaptureReviewController.getReviewData(caps[0].Id);
            Assert.isFalse(after.canReview);
            Assert.isNotNull(after.matchedContactName);
            Assert.isNotNull(after.consentName);
        }
        Capture__c matched = [SELECT Matching_Status__c, Processing_Stage__c, Matched_By__c, Reviewed_By__c, Consent__c FROM Capture__c WHERE Id = :caps[0].Id];
        Assert.areEqual(CaptureConstants.MATCH_REVIEWED, matched.Matching_Status__c);
        Assert.areEqual(CaptureConstants.STAGE_CONSENT_CREATED, matched.Processing_Stage__c);
        Assert.isTrue(matched.Matched_By__c.startsWith('Data steward'));
        Assert.isNotNull(matched.Reviewed_By__c);
        Assert.areEqual(CaptureConstants.CONSENT_CONFIRMED, [SELECT Status__c FROM Consent__c WHERE Id = :matched.Consent__c].Status__c);

        Capture__c created = [SELECT Matching_Status__c, Matched_Contact__c FROM Capture__c WHERE Id = :caps[1].Id];
        Assert.areEqual(CaptureConstants.MATCH_REVIEWED_NEW, created.Matching_Status__c);
        Assert.areEqual(3, [SELECT COUNT() FROM Contact WHERE LastName = 'Esposito']);

        Assert.areEqual(CaptureConstants.STAGE_DISCARDED, [SELECT Processing_Stage__c FROM Capture__c WHERE Id = :caps[2].Id].Processing_Stage__c);
    }

    @IsTest
    static void rerunAndPermissions() {
        List<Capture__c> caps = caps();
        update new Capture__c(Id = caps[0].Id, Matching_Status__c = CaptureConstants.MATCH_ERROR, Processing_Stage__c = CaptureConstants.STAGE_ERROR);
        User steward = ConsentTestFactory.user('HCP_Consent_Data_Steward');
        User nobody = ConsentTestFactory.user(null);
        System.runAs(steward) {
            CaptureReviewController.rerunMatching(caps[0].Id);
            Boolean failed = false;
            try {
                CaptureReviewController.rerunMatching(caps[1].Id);
            } catch (AuraHandledException e) {
                failed = true;
            }
            Assert.isTrue(failed, 'only error/queued captures can be re-run');
        }
        Assert.areEqual(CaptureConstants.MATCH_REVIEW, [SELECT Matching_Status__c FROM Capture__c WHERE Id = :caps[0].Id].Matching_Status__c);
        System.runAs(nobody) {
            Boolean failed = false;
            try {
                CaptureReviewController.discard(caps[1].Id);
            } catch (AuraHandledException e) {
                failed = true;
            }
            Assert.isTrue(failed, 'stewards only');
            Assert.isFalse(CaptureReviewController.getReviewData(caps[1].Id).canReview);
        }
    }
}
