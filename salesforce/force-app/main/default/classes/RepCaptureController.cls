/**
 * Apex behind the rep capture page (Experience Cloud page for internal users,
 * also available as the "Rep Capture Hub" Lightning tab).
 * Search first -> consent status drives the options -> capture saved to staging.
 */
public with sharing class RepCaptureController {
    public class RepContext {
        @AuraEnabled
        public String repName;
        @AuraEnabled
        public String territory;
        @AuraEnabled
        public List<EventOption> events;
        @AuraEnabled
        public ConsentCaptureConfig.ConsentText consent;
        @AuraEnabled
        public List<String> specialties;
    }

    public class EventOption {
        @AuraEnabled
        public String id;
        @AuraEnabled
        public String name;
        @AuraEnabled
        public String dates;
        @AuraEnabled
        public String typeLabel;
        @AuraEnabled
        public Boolean live;
    }

    public class HcpResult {
        @AuraEnabled
        public String id;
        @AuraEnabled
        public String firstName;
        @AuraEnabled
        public String lastName;
        @AuraEnabled
        public String specialty;
        @AuraEnabled
        public String city;
        @AuraEnabled
        public String organisation;
        @AuraEnabled
        public String oneKeyId;
        @AuraEnabled
        public String email;
        @AuraEnabled
        public String registrationNumber;
        /** valid | none | optout | pending */
        @AuraEnabled
        public String consentStatus;
        @AuraEnabled
        public String consentDate;
        @AuraEnabled
        public String consentVersion;
        @AuraEnabled
        public Boolean alreadyAdded;
    }

    public class WalkIn {
        @AuraEnabled
        public String firstName { get; set; }
        @AuraEnabled
        public String lastName { get; set; }
        @AuraEnabled
        public String email { get; set; }
        @AuraEnabled
        public String specialty { get; set; }
        @AuraEnabled
        public String city { get; set; }
        @AuraEnabled
        public String organisation { get; set; }
        @AuraEnabled
        public String registrationNumber { get; set; }
        @AuraEnabled
        public String notes { get; set; }
        @AuraEnabled
        public String interest { get; set; }
        @AuraEnabled
        public Boolean createTask { get; set; }
        @AuraEnabled
        public String taskTitle { get; set; }
        @AuraEnabled
        public Date taskDueDate { get; set; }
    }

    public class SaveResult {
        @AuraEnabled
        public String captureName;
        @AuraEnabled
        public String message;
        @AuraEnabled
        public Boolean emailSent;
    }

    public class MyCapture {
        @AuraEnabled
        public String id;
        @AuraEnabled
        public String name;
        @AuraEnabled
        public String fullName;
        @AuraEnabled
        public String specialty;
        @AuraEnabled
        public String city;
        @AuraEnabled
        public String timeLabel;
        @AuraEnabled
        public String consentLabel;
        /** ok | wait | red */
        @AuraEnabled
        public String consentVariant;
        @AuraEnabled
        public Boolean hasTask;
    }

    // ------------------------------------------------------------ access

    private static void checkAccess() {
        if (!FeatureManagement.checkPermission(CaptureConstants.PERM_REP)) {
            throw new AuraHandledException('You do not have access to the rep capture page (permission set HCP Consent - Rep).');
        }
    }

    private static User me() {
        return [SELECT Id, Name, Territory__c FROM User WHERE Id = :UserInfo.getUserId()];
    }

    // ------------------------------------------------------------ context

    @AuraEnabled
    public static RepContext getContext() {
        checkAccess();
        User u = me();
        RepContext ctx = new RepContext();
        ctx.repName = u.Name;
        ctx.territory = u.Territory__c;
        ctx.consent = ConsentCaptureConfig.activeConsentText();
        ctx.specialties = ConsentCaptureConfig.specialties();
        ctx.events = new List<EventOption>();
        Date today = Date.today();
        for (Event__c ev : [
            SELECT Id, Name, Event_Type__c, Start_Date__c, End_Date__c, Location__c
            FROM Event__c
            WHERE Active__c = TRUE
            ORDER BY Start_Date__c DESC NULLS LAST
            LIMIT 50
        ]) {
            EventOption o = new EventOption();
            o.id = ev.Id;
            o.name = ev.Name;
            o.dates = PublicCaptureController.formatDates(ev.Start_Date__c, ev.End_Date__c);
            o.typeLabel = ev.Event_Type__c + (String.isBlank(ev.Location__c) ? '' : ' · ' + ev.Location__c);
            Date endDate = ev.End_Date__c == null ? ev.Start_Date__c : ev.End_Date__c;
            o.live = ev.Start_Date__c != null && ev.Start_Date__c <= today && endDate >= today;
            ctx.events.add(o);
        }
        return ctx;
    }

    // ------------------------------------------------------------ search

    @AuraEnabled
    public static List<HcpResult> searchHcps(String term, String eventId) {
        checkAccess();
        List<HcpResult> results = new List<HcpResult>();
        String t = term == null ? '' : term.trim();
        if (t.length() < 2) {
            return results;
        }
        User u = me();
        if (String.isBlank(u.Territory__c)) {
            throw new AuraHandledException('No territory is set on your user (User.Territory__c). Ask your admin.');
        }
        String likeTerm = '%' + t + '%';
        String regLikeTerm = '%' + t.toUpperCase().replaceAll('[^A-Z0-9]', '') + '%';
        String territory = u.Territory__c;
        List<Contact> contacts = [
            SELECT
                Id,
                FirstName,
                LastName,
                Email,
                Specialty__c,
                MailingCity,
                Registration_Number__c,
                OneKey_Id__c,
                Consent_Status__c,
                Consent_Status_Date__c,
                Consent_Text_Version__c,
                Account.Name
            FROM Contact
            WHERE
                Territory__c = :territory
                AND (Name LIKE :likeTerm
                OR Email LIKE :likeTerm
                OR Registration_Number__c LIKE :likeTerm
                OR (Registration_Key__c LIKE :regLikeTerm AND Registration_Key__c != NULL))
            ORDER BY LastName, FirstName
            LIMIT 20
        ];
        Set<Id> added = alreadyAdded(eventId, contacts);
        for (Contact c : contacts) {
            results.add(toResult(c, added.contains(c.Id)));
        }
        return results;
    }

    private static Set<Id> alreadyAdded(String eventId, List<Contact> contacts) {
        Set<Id> ids = new Set<Id>();
        if (String.isBlank(eventId) || contacts.isEmpty()) {
            return ids;
        }
        Set<Id> contactIds = new Map<Id, Contact>(contacts).keySet();
        for (Capture__c c : [
            SELECT Matched_Contact__c
            FROM Capture__c
            WHERE Event__c = :eventId AND Matched_Contact__c IN :contactIds AND Captured_By__c = :UserInfo.getUserId()
        ]) {
            ids.add(c.Matched_Contact__c);
        }
        return ids;
    }

    private static HcpResult toResult(Contact c, Boolean added) {
        HcpResult r = new HcpResult();
        r.id = c.Id;
        r.firstName = c.FirstName;
        r.lastName = c.LastName;
        r.specialty = c.Specialty__c;
        r.city = c.MailingCity;
        r.organisation = c.Account == null ? null : c.Account.Name;
        r.oneKeyId = c.OneKey_Id__c;
        r.email = c.Email;
        r.registrationNumber = c.Registration_Number__c;
        r.consentStatus = statusKey(c.Consent_Status__c);
        r.consentDate = c.Consent_Status_Date__c == null ? null : c.Consent_Status_Date__c.format();
        r.consentVersion = c.Consent_Text_Version__c;
        r.alreadyAdded = added;
        return r;
    }

    private static String statusKey(String status) {
        if (status == CaptureConstants.HCP_OPTIN) {
            return 'valid';
        }
        if (status == CaptureConstants.HCP_OPTOUT) {
            return 'optout';
        }
        if (status == CaptureConstants.HCP_PENDING) {
            return 'pending';
        }
        return 'none';
    }

    // ------------------------------------------------------------ known HCP

    /**
     * Adds an HCP found by search to the event.
     * method: 'sign' | 'email' | 'declined' (ignored when a valid opt-in is on file).
     */
    @AuraEnabled
    public static SaveResult addKnownHcp(String eventId, String contactId, String method, String signatureDataUrl) {
        checkAccess();
        Event__c ev = loadEvent(eventId);
        User u = me();
        List<Contact> rows = [
            SELECT Id, FirstName, LastName, Email, Specialty__c, MailingCity, Registration_Number__c, Consent_Status__c, Territory__c, Account.Name
            FROM Contact
            WHERE Id = :contactId
        ];
        if (rows.isEmpty() || rows[0].Territory__c != u.Territory__c) {
            throw new AuraHandledException('HCP not found in your territory.');
        }
        Contact c = rows[0];
        String status = statusKey(c.Consent_Status__c);
        String m = status == 'valid' ? 'existing' : method;
        validateMethod(m, status, c.Email, signatureDataUrl);

        Capture__c cap = baseCapture(ev, u, m);
        cap.First_Name__c = c.FirstName;
        cap.Last_Name__c = c.LastName;
        cap.Email__c = c.Email;
        cap.Specialty__c = c.Specialty__c;
        cap.City__c = c.MailingCity;
        cap.Organisation__c = c.Account == null ? null : c.Account.Name;
        cap.Registration_Number__c = c.Registration_Number__c;
        cap.HCP_Selected_By_Rep__c = true;
        cap.Matched_Contact__c = c.Id;
        return save(cap, m, signatureDataUrl, ev.Name, null);
    }

    // ------------------------------------------------------------ walk-in

    @AuraEnabled
    public static SaveResult saveWalkIn(String eventId, WalkIn data, String method, String signatureDataUrl) {
        checkAccess();
        if (data == null || String.isBlank(data.firstName) || String.isBlank(data.lastName)) {
            throw new AuraHandledException('First and last name are required.');
        }
        if (method == 'existing') {
            throw new AuraHandledException('Choose a consent option.');
        }
        validateMethod(method, 'none', data.email, signatureDataUrl);
        Event__c ev = loadEvent(eventId);
        User u = me();
        Capture__c cap = baseCapture(ev, u, method);
        cap.First_Name__c = data.firstName.trim().left(80);
        cap.Last_Name__c = data.lastName.trim().left(80);
        cap.Email__c = String.isBlank(data.email) ? null : data.email.trim().toLowerCase();
        cap.Specialty__c = String.isBlank(data.specialty) ? null : data.specialty;
        cap.City__c = String.isBlank(data.city) ? null : data.city.trim().left(80);
        cap.Organisation__c = String.isBlank(data.organisation) ? null : data.organisation.trim().left(255);
        cap.Registration_Number__c = String.isBlank(data.registrationNumber) ? null : data.registrationNumber.trim().left(30);
        cap.Notes__c = data.notes == null ? null : data.notes.left(32000);
        cap.Interest__c = String.isBlank(data.interest) ? null : data.interest.left(255);
        Task follow = null;
        if (data.createTask == true && String.isNotBlank(data.taskTitle)) {
            follow = new Task(
                Subject = data.taskTitle.left(255),
                ActivityDate = data.taskDueDate,
                OwnerId = u.Id,
                Status = 'Not Started',
                Priority = 'Normal',
                Description = data.notes == null ? null : data.notes.left(32000)
            );
        }
        return save(cap, method, signatureDataUrl, ev.Name, follow);
    }

    @AuraEnabled
    public static NotesExtractionService.Result extractFromNotes(String notes) {
        checkAccess();
        return NotesExtractionService.extract(notes);
    }

    // ------------------------------------------------------------ my captures

    @AuraEnabled
    public static List<MyCapture> getMyCapturesToday() {
        checkAccess();
        List<MyCapture> out = new List<MyCapture>();
        for (Capture__c c : [
            SELECT
                Id,
                Name,
                First_Name__c,
                Last_Name__c,
                Specialty__c,
                City__c,
                Captured_At__c,
                Consent_Method__c,
                Opt_In_Status__c,
                (SELECT Id FROM Tasks LIMIT 1)
            FROM Capture__c
            WHERE Captured_By__c = :UserInfo.getUserId() AND CreatedDate = TODAY
            ORDER BY CreatedDate DESC
            LIMIT 200
        ]) {
            MyCapture m = new MyCapture();
            m.id = c.Id;
            m.name = c.Name;
            m.fullName = (c.First_Name__c == null ? '' : c.First_Name__c + ' ') + c.Last_Name__c;
            m.specialty = c.Specialty__c;
            m.city = c.City__c;
            m.timeLabel = c.Captured_At__c == null ? '' : c.Captured_At__c.format('HH:mm');
            if (c.Opt_In_Status__c == CaptureConstants.OPTIN_CONFIRMED) {
                m.consentVariant = 'ok';
                m.consentLabel = c.Consent_Method__c == CaptureConstants.METHOD_SIGNATURE
                    ? 'Consent signed'
                    : (c.Consent_Method__c == CaptureConstants.METHOD_EXISTING ? 'Consent on file' : 'Consent confirmed');
            } else if (c.Opt_In_Status__c == CaptureConstants.OPTIN_DECLINED) {
                m.consentVariant = 'red';
                m.consentLabel = 'Consent declined';
            } else {
                m.consentVariant = 'wait';
                m.consentLabel = 'Consent pending';
            }
            m.hasTask = !c.Tasks.isEmpty();
            out.add(m);
        }
        return out;
    }

    // ------------------------------------------------------------ helpers

    private static Event__c loadEvent(String eventId) {
        List<Event__c> rows = [SELECT Id, Name FROM Event__c WHERE Id = :eventId AND Active__c = TRUE LIMIT 1];
        if (rows.isEmpty()) {
            throw new AuraHandledException('Select an active event first.');
        }
        return rows[0];
    }

    private static void validateMethod(String method, String status, String email, String signatureDataUrl) {
        if (method == 'existing') {
            return;
        }
        if (method != 'sign' && method != 'email' && method != 'declined') {
            throw new AuraHandledException('Choose a consent option.');
        }
        if (status == 'optout' && method == 'email') {
            throw new AuraHandledException('This HCP opted out: consent can only be re-collected with the explicit question and a signature.');
        }
        if (method == 'sign' && String.isBlank(signatureDataUrl)) {
            throw new AuraHandledException('The HCP signature is required.');
        }
        if (method == 'email' && String.isBlank(email)) {
            throw new AuraHandledException('An email address is needed to send the confirmation link.');
        }
    }

    private static Capture__c baseCapture(Event__c ev, User u, String method) {
        ConsentCaptureConfig.ConsentText text = ConsentCaptureConfig.activeConsentText();
        Capture__c cap = new Capture__c(
            Event__c = ev.Id,
            Channel__c = CaptureConstants.CHANNEL_REP,
            Captured_By__c = u.Id,
            Captured_By_Name__c = u.Name,
            Captured_At__c = System.now(),
            Consent_Text_Version__c = text.version,
            Send_Slides__c = method != 'declined',
            Processing_Stage__c = CaptureConstants.STAGE_RECEIVED,
            Matching_Status__c = CaptureConstants.MATCH_QUEUED,
            Confirmation_Email_Status__c = CaptureConstants.EMAIL_NOT_REQUIRED
        );
        if (method == 'existing') {
            cap.Consent_Method__c = CaptureConstants.METHOD_EXISTING;
            cap.Consent_Given__c = true;
            cap.Opt_In_Status__c = CaptureConstants.OPTIN_CONFIRMED;
        } else if (method == 'sign') {
            cap.Consent_Method__c = CaptureConstants.METHOD_SIGNATURE;
            cap.Consent_Given__c = true;
            cap.Opt_In_Status__c = CaptureConstants.OPTIN_CONFIRMED;
            cap.Opt_In_Confirmed_At__c = cap.Captured_At__c;
            cap.Signature_Captured__c = true;
        } else if (method == 'email') {
            cap.Consent_Method__c = CaptureConstants.METHOD_EMAIL;
            cap.Consent_Given__c = true;
            cap.Opt_In_Status__c = CaptureConstants.OPTIN_PENDING;
        } else {
            cap.Consent_Method__c = CaptureConstants.METHOD_DECLINED;
            cap.Consent_Given__c = false;
            cap.Opt_In_Status__c = CaptureConstants.OPTIN_DECLINED;
        }
        return cap;
    }

    private static SaveResult save(Capture__c cap, String method, String signatureDataUrl, String eventName, Task follow) {
        String token = method == 'email' ? ConsentService.attachNewToken(cap) : null;
        insert cap;
        Capture__c saved = [SELECT Id, Name FROM Capture__c WHERE Id = :cap.Id];
        if (method == 'sign') {
            ConsentService.saveSignature(cap.Id, saved.Name, signatureDataUrl);
        }
        if (follow != null) {
            follow.WhatId = cap.Id;
            insert follow;
        }
        SaveResult r = new SaveResult();
        r.captureName = saved.Name;
        r.emailSent = false;
        if (token != null) {
            r.emailSent = ConsentService.sendConfirmationEmail(cap.Email__c, cap.Last_Name__c, eventName, token);
            update new Capture__c(
                Id = cap.Id,
                Confirmation_Email_Status__c = r.emailSent ? CaptureConstants.EMAIL_SENT : CaptureConstants.EMAIL_FAILED
            );
        }
        if (method == 'existing') {
            r.message = 'Consent already on file - nothing to ask.';
        } else if (method == 'sign') {
            r.message = 'Signed on screen - consent confirmed and recorded.';
        } else if (method == 'email') {
            r.message = r.emailSent
                ? 'Confirmation link sent by email - consent pending until the HCP confirms.'
                : 'Capture saved, but the confirmation email could not be sent (check email settings). Consent stays pending.';
        } else {
            r.message = 'HCP declined - added as attendee only, no communications.';
        }
        return r;
    }
}
