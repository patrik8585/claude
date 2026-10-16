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
        @AuraEnabled
        public String territory;
        @AuraEnabled
        public Boolean inMyTerritory;
        @AuraEnabled
        public String hospital;
        @AuraEnabled
        public String department;
        /** All active affiliations, primary first. */
        @AuraEnabled
        public String affiliations;
        /** For the selected event: registered | attended | null (not registered, not seen yet). */
        @AuraEnabled
        public String attendance;
    }

    public class RegisteredList {
        @AuraEnabled
        public Integer registered = 0;
        @AuraEnabled
        public Integer checkedIn = 0;
        /** Not checked in first, then by name. */
        @AuraEnabled
        public List<HcpResult> attendees = new List<HcpResult>();
    }

    public class HcoOption {
        @AuraEnabled
        public String id;
        @AuraEnabled
        public String name;
        @AuraEnabled
        public String city;
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
        public String hospitalId { get; set; }
        @AuraEnabled
        public String departmentId { get; set; }
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
        /** The rep's notes (typed or dictated), shown under the capture. */
        @AuraEnabled
        public String notes;
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
        // All HCPs the rep can see in Salesforce are searchable; the rep's own territory is listed first.
        User u = me();
        String likeTerm = '%' + t + '%';
        String regLikeTerm = '%' + t.toUpperCase().replaceAll('[^A-Z0-9]', '') + '%';
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
                Territory__c,
                Consent_Status__c,
                Consent_Status_Date__c,
                Consent_Text_Version__c,
                AccountId,
                Account.Name
            FROM Contact
            WHERE
                Name LIKE :likeTerm
                OR Email LIKE :likeTerm
                OR Registration_Number__c LIKE :likeTerm
                OR (Registration_Key__c LIKE :regLikeTerm AND Registration_Key__c != NULL)
            ORDER BY LastName, FirstName
            LIMIT 50
        ];
        Set<Id> added = alreadyAdded(eventId, contacts);
        Map<Id, String> attendance = attendanceByContact(eventId, new Map<Id, Contact>(contacts).keySet());
        Map<Id, String> affiliations = CaptureReviewController.affiliationLabels(new Map<Id, Contact>(contacts).keySet());
        List<HcpResult> mine = new List<HcpResult>();
        List<HcpResult> others = new List<HcpResult>();
        for (Contact c : contacts) {
            HcpResult r = toResult(c, added.contains(c.Id));
            r.affiliations = affiliations.get(c.Id);
            r.attendance = attendance.get(c.Id);
            r.territory = c.Territory__c;
            r.inMyTerritory = String.isNotBlank(u.Territory__c) && c.Territory__c == u.Territory__c;
            if (r.inMyTerritory) {
                mine.add(r);
            } else {
                others.add(r);
            }
        }
        results.addAll(mine);
        results.addAll(others);
        return results;
    }

    /** registered | attended per HCP for the event (registered = imported registration, not checked in yet). */
    private static Map<Id, String> attendanceByContact(String eventId, Set<Id> contactIds) {
        Map<Id, String> out = new Map<Id, String>();
        if (String.isBlank(eventId) || contactIds.isEmpty()) {
            return out;
        }
        for (Event_Attendee__c a : [
            SELECT Contact__c, Attendance_Status__c, Registered__c
            FROM Event_Attendee__c
            WHERE Event__c = :eventId AND Contact__c IN :contactIds
        ]) {
            if (a.Attendance_Status__c == CaptureConstants.ATTENDANCE_ATTENDED) {
                out.put(a.Contact__c, 'attended');
            } else if (a.Registered__c) {
                out.put(a.Contact__c, 'registered');
            }
        }
        return out;
    }

    /** HCPs registered for the event before it started, for the rep's check-in list. */
    @AuraEnabled
    public static RegisteredList getRegisteredAttendees(String eventId) {
        checkAccess();
        RegisteredList out = new RegisteredList();
        if (String.isBlank(eventId)) {
            return out;
        }
        Map<Id, String> attendance = new Map<Id, String>();
        for (Event_Attendee__c a : [
            SELECT Contact__c, Attendance_Status__c
            FROM Event_Attendee__c
            WHERE Event__c = :eventId AND Registered__c = TRUE
            LIMIT 2000
        ]) {
            Boolean attended = a.Attendance_Status__c == CaptureConstants.ATTENDANCE_ATTENDED;
            attendance.put(a.Contact__c, attended ? 'attended' : 'registered');
            out.registered++;
            if (attended) {
                out.checkedIn++;
            }
        }
        if (attendance.isEmpty()) {
            return out;
        }
        Set<Id> contactIds = attendance.keySet();
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
                Territory__c,
                Consent_Status__c,
                Consent_Status_Date__c,
                Consent_Text_Version__c,
                AccountId,
                Account.Name
            FROM Contact
            WHERE Id IN :contactIds
            ORDER BY LastName, FirstName
            LIMIT 2000
        ];
        Set<Id> added = alreadyAdded(eventId, contacts);
        Map<Id, String> affiliations = CaptureReviewController.affiliationLabels(contactIds);
        User u = me();
        List<HcpResult> waiting = new List<HcpResult>();
        List<HcpResult> done = new List<HcpResult>();
        for (Contact c : contacts) {
            HcpResult r = toResult(c, added.contains(c.Id));
            r.affiliations = affiliations.get(c.Id);
            r.attendance = attendance.get(c.Id);
            r.territory = c.Territory__c;
            r.inMyTerritory = String.isNotBlank(u.Territory__c) && c.Territory__c == u.Territory__c;
            if (r.attendance == 'attended') {
                done.add(r);
            } else {
                waiting.add(r);
            }
        }
        out.attendees.addAll(waiting);
        out.attendees.addAll(done);
        return out;
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
        HcoDirectory dir = HcoDirectory.get();
        Id hospitalId = dir.hospitalOf(c.AccountId);
        if (hospitalId != null) {
            r.hospital = dir.hospitalName(hospitalId);
            r.organisation = r.hospital;
            if (dir.isDepartment(c.AccountId)) {
                Account d = dir.departments.get(c.AccountId);
                r.department = String.isBlank(d.Department_Type__c) ? d.Name : d.Department_Type__c;
            }
        }
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
    public static SaveResult addKnownHcp(String eventId, String contactId, String method, String signatureDataUrl, String deviceInfo) {
        checkAccess();
        Event__c ev = loadEvent(eventId);
        User u = me();
        List<Contact> rows = [
            SELECT Id, FirstName, LastName, Email, Specialty__c, MailingCity, Registration_Number__c, Consent_Status__c, Territory__c, AccountId, Account.Name
            FROM Contact
            WHERE Id = :contactId
        ];
        if (rows.isEmpty()) {
            throw new AuraHandledException('HCP not found.');
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
        HcoDirectory dir = HcoDirectory.get();
        cap.Hospital__c = dir.hospitalOf(c.AccountId);
        if (cap.Hospital__c != null) {
            cap.Organisation__c = dir.hospitalName(cap.Hospital__c);
            cap.Department__c = dir.isDepartment(c.AccountId) ? c.AccountId : null;
        }
        cap.Registration_Number__c = c.Registration_Number__c;
        cap.HCP_Selected_By_Rep__c = true;
        cap.Matched_Contact__c = c.Id;
        cap.Capture_Device__c = deviceInfo == null ? null : deviceInfo.left(255);
        return save(cap, m, signatureDataUrl, ev.Name, null);
    }

    // ------------------------------------------------------------ walk-in

    @AuraEnabled
    public static SaveResult saveWalkIn(String eventId, WalkIn data, String method, String signatureDataUrl, String deviceInfo) {
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
        applyHco(cap, data.hospitalId, data.departmentId);
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
        cap.Capture_Device__c = deviceInfo == null ? null : deviceInfo.left(255);
        return save(cap, method, signatureDataUrl, ev.Name, follow);
    }

    // ------------------------------------------------------------ hospitals and departments

    /** Hospitals whose name, alias or city contains the term (walk-in form). */
    @AuraEnabled
    public static List<HcoOption> searchHospitals(String term) {
        checkAccess();
        List<HcoOption> out = new List<HcoOption>();
        String t = HcpMatchEngine.normalize(term);
        if (t.length() < 2) {
            return out;
        }
        HcoDirectory dir = HcoDirectory.get();
        for (Account h : dir.hospitals.values()) {
            String hay = HcpMatchEngine.normalize(h.Name) + '|' + HcpMatchEngine.normalize(h.Aliases__c) + '|' + HcpMatchEngine.normalize(h.BillingCity);
            if (hay.contains(t)) {
                HcoOption o = new HcoOption();
                o.id = h.Id;
                o.name = h.Name;
                o.city = h.BillingCity;
                out.add(o);
                if (out.size() >= 20) {
                    break;
                }
            }
        }
        return out;
    }

    @AuraEnabled
    public static List<HcoOption> getDepartments(String hospitalId) {
        checkAccess();
        List<HcoOption> out = new List<HcoOption>();
        if (String.isBlank(hospitalId)) {
            return out;
        }
        List<Account> depts = HcoDirectory.get().departmentsByHospital.get(Id.valueOf(hospitalId));
        if (depts == null) {
            return out;
        }
        for (Account d : depts) {
            HcoOption o = new HcoOption();
            o.id = d.Id;
            o.name = String.isBlank(d.Department_Type__c) ? d.Name : d.Department_Type__c;
            o.city = d.BillingCity;
            out.add(o);
        }
        return out;
    }

    /** Sets hospital / department chosen by the rep (validated against the directory). */
    private static void applyHco(Capture__c cap, String hospitalId, String departmentId) {
        HcoDirectory dir = HcoDirectory.get();
        Id dept = String.isBlank(departmentId) ? null : Id.valueOf(departmentId);
        Id hosp = String.isBlank(hospitalId) ? null : Id.valueOf(hospitalId);
        if (dept != null && dir.isDepartment(dept)) {
            cap.Department__c = dept;
            hosp = dir.hospitalOf(dept);
        }
        if (hosp != null && dir.hospitals.containsKey(hosp)) {
            cap.Hospital__c = hosp;
            if (String.isBlank(cap.Organisation__c)) {
                cap.Organisation__c = dir.hospitalName(hosp);
            }
        }
    }

    @AuraEnabled
    public static NotesExtractionService.Result extractFromNotes(String notes) {
        checkAccess();
        return NotesExtractionService.extractSmart(notes);
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
                Notes__c,
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
            m.notes = c.Notes__c;
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
        Boolean copySent = false;
        if (method == 'sign') {
            String sigHash = ConsentService.saveSignature(cap.Id, saved.Name, signatureDataUrl);
            copySent = ConsentService.sendSignedCopyEmail(cap.Email__c, cap.Last_Name__c, eventName, cap.Captured_At__c, cap.Captured_By_Name__c);
            update new Capture__c(
                Id = cap.Id,
                Signature_Hash__c = sigHash,
                Signature_Copy_Sent__c = copySent,
                Email_Error__c = copySent ? null : ConsentService.lastEmailError
            );
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
                Confirmation_Email_Status__c = r.emailSent ? CaptureConstants.EMAIL_SENT : CaptureConstants.EMAIL_FAILED,
                Email_Error__c = r.emailSent ? null : ConsentService.lastEmailError
            );
        }
        if (method == 'existing') {
            r.message = 'Consent already on file - nothing to ask.';
        } else if (method == 'sign') {
            r.message = 'Signed on screen - consent confirmed and recorded.' +
                (copySent ? ' A copy was emailed to the HCP.' : '');
        } else if (method == 'email') {
            r.message = r.emailSent
                ? 'Confirmation link sent by email - consent pending until the HCP confirms.'
                : 'Capture saved, but the confirmation email could not be sent (' + ConsentService.lastEmailError + '). Consent stays pending.';
        } else {
            r.message = 'HCP declined - added as attendee only, no communications.';
        }
        return r;
    }
}
