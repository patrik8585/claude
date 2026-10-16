// Email diagnostics: prints the settings the confirmation email depends on, the org's remaining daily
// single-email allowance, and sends one test email to YOUR user email address. Look for "EMAIL CHECK" lines.
Consent_Capture_Settings__c s = Consent_Capture_Settings__c.getOrgDefaults();
System.debug('EMAIL CHECK public site URL: ' + s.Public_Site_Url__c);
System.debug('EMAIL CHECK org-wide address setting: ' + s.Org_Wide_Email_Address__c);
if (String.isNotBlank(s.Org_Wide_Email_Address__c)) {
    System.debug('EMAIL CHECK org-wide address found in Setup: ' + ![SELECT Id FROM OrgWideEmailAddress WHERE Address = :s.Org_Wide_Email_Address__c].isEmpty());
}
System.OrgLimit single = OrgLimits.getMap().get('SingleEmail');
if (single != null) {
    System.debug('EMAIL CHECK single emails used today: ' + single.getValue() + ' of ' + single.getLimit());
}
try {
    Messaging.reserveSingleEmailCapacity(1);
    System.debug('EMAIL CHECK capacity reservation: OK');
} catch (Exception e) {
    System.debug('EMAIL CHECK capacity reservation FAILED: ' + e.getMessage());
}
Boolean sent = ConsentService.sendConfirmationEmail(UserInfo.getUserEmail(), 'Test', 'Email test', ConsentService.newToken());
System.debug('EMAIL CHECK test email to ' + UserInfo.getUserEmail() + ': ' + (sent ? 'SENT (check inbox and spam)' : 'FAILED - ' + ConsentService.lastEmailError));
for (Capture__c c : [
    SELECT Name, Email__c, Confirmation_Email_Status__c, Email_Error__c, CreatedDate
    FROM Capture__c
    WHERE Confirmation_Email_Status__c != NULL
    ORDER BY CreatedDate DESC
    LIMIT 5
]) {
    System.debug('EMAIL CHECK last captures: ' + c.Name + ' ' + c.Email__c + ' ' + c.Confirmation_Email_Status__c + ' ' + c.Email_Error__c);
}
