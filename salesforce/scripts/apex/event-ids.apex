// Prints the event Ids and the public URLs to put in the QR codes / kiosk tablets.
String base = Consent_Capture_Settings__c.getOrgDefaults().Public_Site_Url__c;
for (Event__c e : [SELECT Id, Name FROM Event__c WHERE Active__c = true]) {
    System.debug(e.Name + '\n  QR:    ' + base + '?e=' + e.Id + '&ch=qr\n  Kiosk: ' + base + '?e=' + e.Id + '&mode=kiosk');
}
