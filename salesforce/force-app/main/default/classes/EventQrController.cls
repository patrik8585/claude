/**
 * Event record page: public URLs (booth QR / kiosk) for an event, used by the
 * eventQrCodes LWC to render and download QR codes for congress posters.
 */
public with sharing class EventQrController {
    public class QrInfo {
        @AuraEnabled
        public String eventName;
        @AuraEnabled
        public Boolean configured;
        @AuraEnabled
        public Boolean publicEnabled;
        @AuraEnabled
        public String selfScanUrl;
        @AuraEnabled
        public String kioskUrl;
        @AuraEnabled
        public String fileName;
    }

    @AuraEnabled
    public static QrInfo getQrInfo(Id eventId) {
        if (!FeatureManagement.checkPermission(CaptureConstants.PERM_STEWARD)) {
            throw new AuraHandledException('Only admins and data stewards can download event QR codes.');
        }
        Event__c ev = [SELECT Id, Name, Short_Name__c, Active__c, Public_Capture_Enabled__c FROM Event__c WHERE Id = :eventId];
        String base = ConsentCaptureConfig.publicSiteUrl();
        QrInfo info = new QrInfo();
        info.eventName = ev.Name;
        info.publicEnabled = ev.Active__c && ev.Public_Capture_Enabled__c;
        info.configured = String.isNotBlank(base) && !base.contains('REPLACE-ME') && !base.contains('/lightning/');
        info.fileName = (String.isBlank(ev.Short_Name__c) ? ev.Name : ev.Short_Name__c).replaceAll('[^A-Za-z0-9]+', '-').removeEnd('-');
        if (info.configured) {
            String sep = base.contains('?') ? '&' : '?';
            info.selfScanUrl = base + sep + 'e=' + ev.Id + '&ch=qr';
            info.kioskUrl = base + sep + 'e=' + ev.Id + '&mode=kiosk';
        }
        return info;
    }
}
