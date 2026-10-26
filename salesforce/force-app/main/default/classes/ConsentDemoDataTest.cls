@IsTest
private class ConsentDemoDataTest {
    @IsTest
    static void loadsMockupDataAndMatches() {
        // hospitals and departments use Account record types granted by the admin permission set
        System.runAs(ConsentTestFactory.user('HCP_Consent_Admin')) {
            loadAndCheck();
        }
    }

    private static void loadAndCheck() {
        ConsentDemoData.configure('https://example.my.site.com/hcp/');
        Assert.areEqual('https://example.my.site.com/hcp', Consent_Capture_Settings__c.getOrgDefaults().Public_Site_Url__c);
        Assert.isNotNull(Consent_Capture_Settings__c.getOrgDefaults().Form_Secret__c);

        Test.startTest();
        ConsentDemoData.run();
        Test.stopTest();

        Assert.areEqual(14 + 2, [SELECT COUNT() FROM Contact], '14 HCPs + 2 new HCPs from captures');
        Assert.areEqual(14 + 1, [SELECT COUNT() FROM HCP_Affiliation__c], 'one primary affiliation each, Rinaldi in 2 departments');
        Assert.areEqual(
            'Paediatrics - Gaslini Institute',
            [SELECT Account.Name FROM Contact WHERE Email = 'm.bianchi@gaslini-example.it'].Account.Name
        );
        Capture__c bianchi = [SELECT Hospital__r.Name, Suggestion_Confidence__c FROM Capture__c WHERE Email__c = 'maria.bianchi@gmail.com'];
        Assert.areEqual('Gaslini Institute', bianchi.Hospital__r.Name, 'hospital resolved from "Gaslini"');
        Assert.areEqual('High', bianchi.Suggestion_Confidence__c);
        Assert.areEqual(12, [SELECT COUNT() FROM Capture__c]);
        Assert.areEqual(8, [SELECT COUNT() FROM Capture__c WHERE Matching_Status__c = :CaptureConstants.MATCH_AUTO]);
        Assert.areEqual(2, [SELECT COUNT() FROM Capture__c WHERE Matching_Status__c = :CaptureConstants.MATCH_REVIEW]);
        Assert.areEqual(2, [SELECT COUNT() FROM Capture__c WHERE Matching_Status__c = :CaptureConstants.MATCH_NEW]);
        Assert.areEqual(
            CaptureConstants.HCP_OPTOUT,
            [SELECT Consent_Status__c FROM Contact WHERE Email = 'paolo.conti@aosp-example.it'].Consent_Status__c,
            'a pending self-scan does not override an opt-out'
        );
        Assert.areEqual(
            CaptureConstants.HCP_OPTIN,
            [SELECT Consent_Status__c FROM Contact WHERE Email = 'laura.benedetti@ospedale-example.it'].Consent_Status__c
        );
        Assert.isTrue(ConsentDemoData.simulateGigyaSync() > 0);

        Boolean failed = false;
        try {
            ConsentDemoData.run();
        } catch (ConsentDemoData.DemoException e) {
            failed = true;
        }
        Assert.isTrue(failed, 'run() refuses to load twice');

        ConsentDemoData.reset();
        Assert.areEqual(0, [SELECT COUNT() FROM Event__c]);
        Assert.areEqual(0, [SELECT COUNT() FROM Capture__c]);
        Assert.areEqual(0, [SELECT COUNT() FROM Contact]);
        Assert.areEqual(0, [SELECT COUNT() FROM Account WHERE Name = 'Gaslini Institute']);
    }

    @IsTest
    static void setsTerritory() {
        ConsentDemoData.setMyTerritory();
        Assert.areEqual(ConsentDemoData.TERRITORY_REP, [SELECT Territory__c FROM User WHERE Id = :UserInfo.getUserId()].Territory__c);
    }
}
