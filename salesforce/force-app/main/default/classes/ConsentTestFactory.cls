@IsTest
public class ConsentTestFactory {
    public static final String TERRITORY = 'IT-PED-01';

    public static Consent_Capture_Settings__c settings() {
        Consent_Capture_Settings__c s = new Consent_Capture_Settings__c(
            SetupOwnerId = UserInfo.getOrganizationId(),
            Form_Secret__c = 'test-secret-0123456789abcdef',
            Public_Site_Url__c = 'https://example.my.site.com/hcp',
            Max_Per_Email_Per_Day__c = 3,
            Max_Per_Event_Per_Minute__c = 100,
            Min_Form_Seconds__c = 0,
            Token_Validity_Days__c = 30
        );
        insert s;
        ConsentCaptureConfig.cached = null;
        return s;
    }

    public static Event__c event() {
        Event__c ev = new Event__c(
            Name = 'Test Congress',
            Short_Name__c = 'Test',
            Event_Type__c = 'Congress',
            Start_Date__c = Date.today(),
            End_Date__c = Date.today().addDays(2),
            Active__c = true,
            Public_Capture_Enabled__c = true,
            Slides_Url__c = 'https://example.com/slides.pdf'
        );
        insert ev;
        return ev;
    }

    public static Contact contact(String first, String last, String email, String spec, String city, String reg) {
        Account a = new Account(Name = 'Hospital ' + last + ' ' + city);
        a.setOptions(CaptureResolutionService.allowDuplicates());
        insert a;
        Contact c = new Contact(
            FirstName = first,
            LastName = last,
            Email = email,
            Specialty__c = spec,
            MailingCity = city,
            Registration_Number__c = reg,
            AccountId = a.Id,
            Territory__c = TERRITORY,
            Consent_Status__c = CaptureConstants.HCP_NONE
        );
        c.setOptions(CaptureResolutionService.allowDuplicates());
        insert c;
        return c;
    }

    public static Consent__c confirmedConsent(Id contactId) {
        Consent__c k = new Consent__c(
            Contact__c = contactId,
            Consent_Type__c = CaptureConstants.CONSENT_TYPE_EMAIL,
            Status__c = CaptureConstants.CONSENT_CONFIRMED,
            Channel__c = CaptureConstants.CHANNEL_PITCHER,
            Captured_At__c = System.now().addDays(-30),
            Confirmed_At__c = System.now().addDays(-30),
            Consent_Text_Version__c = 'v3.1',
            Opt_In_Method__c = CaptureConstants.METHOD_PITCHER,
            Gigya_Status__c = CaptureConstants.GIGYA_SENT
        );
        insert k;
        ConsentService.refreshContactSummary(new Set<Id>{ contactId });
        return k;
    }

    public static Capture__c capture(Event__c ev, String first, String last, String email, String spec, String city) {
        return new Capture__c(
            Event__c = ev.Id,
            First_Name__c = first,
            Last_Name__c = last,
            Email__c = email,
            Specialty__c = spec,
            City__c = city,
            Channel__c = CaptureConstants.CHANNEL_SELF,
            Captured_At__c = System.now(),
            Consent_Given__c = true,
            Consent_Method__c = CaptureConstants.METHOD_EMAIL,
            Opt_In_Status__c = CaptureConstants.OPTIN_PENDING,
            Consent_Text_Version__c = 'v3.2',
            Send_Slides__c = true,
            Processing_Stage__c = CaptureConstants.STAGE_RECEIVED,
            Matching_Status__c = CaptureConstants.MATCH_QUEUED
        );
    }

    /** Admin-profile user with the given permission set (null = none) and the test territory. */
    public static User user(String permissionSetName) {
        List<Profile> profiles = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        if (profiles.isEmpty()) {
            profiles = [SELECT Id FROM Profile WHERE PermissionsModifyAllData = TRUE AND UserType = 'Standard' LIMIT 1];
        }
        String unique = String.valueOf(Crypto.getRandomInteger()).replace('-', '') + String.valueOf(System.currentTimeMillis());
        User u = new User(
            ProfileId = profiles[0].Id,
            Username = 'hcp.consent.' + unique + '@example.com.test',
            Email = 'hcp.consent.test@example.com',
            LastName = 'Tester',
            FirstName = 'Rep',
            Alias = 'hcpt' + unique.left(4),
            TimeZoneSidKey = 'Europe/Rome',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            Territory__c = TERRITORY
        );
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert u;
            if (permissionSetName != null) {
                PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = :permissionSetName LIMIT 1];
                insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps.Id);
            }
        }
        return u;
    }

    public static String signature() {
        return 'data:image/png;base64,' + EncodingUtil.base64Encode(Blob.valueOf('fake-png-bytes'));
    }
}
