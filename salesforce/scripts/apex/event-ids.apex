// Prints the event Ids and the URLs to put in the QR codes / kiosk tablets,
// plus the internal Lightning preview URLs (tab "HCP Public Page (preview)").
String base = Consent_Capture_Settings__c.getOrgDefaults().Public_Site_Url__c;
String lightning = URL.getOrgDomainUrl().toExternalForm().replace('.my.salesforce.com', '.lightning.force.com') + '/lightning/n/HCP_Public_Preview';
for (Event__c e : [SELECT Id, Name FROM Event__c WHERE Active__c = true]) {
    System.debug(e.Name +
        '\n  QR (site):        ' + base + '?e=' + e.Id + '&ch=qr' +
        '\n  Kiosk (site):     ' + base + '?e=' + e.Id + '&mode=kiosk' +
        '\n  Preview (Lightning): ' + lightning + '?c__e=' + e.Id +
        '\n  Preview kiosk:       ' + lightning + '?c__e=' + e.Id + '&c__mode=kiosk');
}
