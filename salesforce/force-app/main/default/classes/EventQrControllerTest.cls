@IsTest
private class EventQrControllerTest {
    @IsTest
    static void returnsSiteUrls() {
        ConsentTestFactory.settings();
        Event__c ev = ConsentTestFactory.event();
        User steward = ConsentTestFactory.user('HCP_Consent_Data_Steward');
        User nobody = ConsentTestFactory.user(null);
        System.runAs(steward) {
            EventQrController.QrInfo info = EventQrController.getQrInfo(ev.Id);
            Assert.isTrue(info.configured, 'site URL configured');
            Assert.isTrue(info.publicEnabled, 'event is public');
            Assert.areEqual('https://example.my.site.com/hcp?e=' + ev.Id + '&ch=qr', info.selfScanUrl);
            Assert.areEqual('https://example.my.site.com/hcp?e=' + ev.Id + '&mode=kiosk', info.kioskUrl);
            Assert.areEqual('Test', info.fileName);
        }
        System.runAs(nobody) {
            Boolean failed = false;
            try {
                EventQrController.getQrInfo(ev.Id);
            } catch (AuraHandledException e) {
                failed = true;
            }
            Assert.isTrue(failed, 'stewards and admins only');
        }
    }

    @IsTest
    static void notConfiguredWithoutSiteUrl() {
        Event__c ev = ConsentTestFactory.event();
        User steward = ConsentTestFactory.user('HCP_Consent_Data_Steward');
        System.runAs(steward) {
            EventQrController.QrInfo info = EventQrController.getQrInfo(ev.Id);
            Assert.isFalse(info.configured, 'no site URL yet');
            Assert.isNull(info.selfScanUrl, 'no URL without a site');
        }
    }
}
