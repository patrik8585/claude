// Prints the congress Ids and the URLs to put in the QR codes / kiosk tablets
// (the same links as the QR codes on the Congress record page).
String base = Consent_Capture_Settings__c.getOrgDefaults().Public_Site_Url__c;
for (Event__c e : [SELECT Id, Name FROM Event__c WHERE Active__c = true]) {
    System.debug(e.Name +
        '\n  QR (site):        ' + base + '?e=' + e.Id + '&ch=qr' +
        '\n  Kiosk (site):     ' + base + '?e=' + e.Id + '&mode=kiosk');
}
