/**
 * Pre-event registrations: the people who registered for an event before it starts
 * (export of the registration website), imported from the Event record page.
 *
 * Each row becomes a Capture__c with Channel "Event registration", so it goes through the same
 * matching as every other capture (existing HCP or steward review). Registrations come before the
 * event, so only HCPs already in Salesforce can be registered: a row that matches nobody is discarded
 * (never a new HCP) and counted as "not in Salesforce". Matching then creates
 * the Event_Attendee__c as Registered (Registered__c = true). A rep check-in, a kiosk or a QR capture
 * later turns it into Attended.
 *
 * Consent: a consent given on the registration website is imported as a confirmed consent
 * (method "Given at event registration"). A row without consent never changes a consent the HCP
 * already has: only an explicit opt-out withdraws it.
 */
public with sharing class EventRegistrationService {
    public static final Integer MAX_ROWS = 2000;
    public static final String IMPORTED_BY = 'Registration import';
    private static final Pattern EMAIL_PATTERN = Pattern.compile('^[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}$');

    public class Registrant {
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
        public String registrationNumber { get; set; }
        @AuraEnabled
        public String organisation { get; set; }
        /** Consent given on the registration website. */
        @AuraEnabled
        public Boolean consent { get; set; }
        /** yyyy-MM-dd; empty = today. */
        @AuraEnabled
        public String consentDate { get; set; }
        /** Consent text version shown at registration; empty = the active version. */
        @AuraEnabled
        public String consentVersion { get; set; }
    }

    public class ImportResult {
        @AuraEnabled
        public Integer imported = 0;
        @AuraEnabled
        public Integer skipped = 0;
        @AuraEnabled
        public List<String> messages = new List<String>();
    }

    public class Summary {
        @AuraEnabled
        public String eventName;
        /** Registered before the event (Registered__c). */
        @AuraEnabled
        public Integer registered = 0;
        /** Registered and already attended (checked in or captured at the event). */
        @AuraEnabled
        public Integer checkedIn = 0;
        /** Registered, not seen yet. */
        @AuraEnabled
        public Integer notArrived = 0;
        /** Attended without a registration. */
        @AuraEnabled
        public Integer walkIns = 0;
        /** Registrations still being matched or waiting for a data steward. */
        @AuraEnabled
        public Integer inProgress = 0;
        /** Registrations discarded because the HCP is not in Salesforce. */
        @AuraEnabled
        public Integer notFound = 0;
        @AuraEnabled
        public Boolean canImport = false;
    }

    // ------------------------------------------------------------ summary

    @AuraEnabled
    public static Summary getSummary(String eventId) {
        Event__c ev = loadEvent(eventId);
        Summary s = new Summary();
        s.eventName = ev.Name;
        s.canImport = FeatureManagement.checkPermission(CaptureConstants.PERM_STEWARD);
        for (AggregateResult ar : [
            SELECT Registered__c reg, Attendance_Status__c st, COUNT(Id) n
            FROM Event_Attendee__c
            WHERE Event__c = :ev.Id
            GROUP BY Registered__c, Attendance_Status__c
        ]) {
            Integer n = (Integer) ar.get('n');
            Boolean reg = (Boolean) ar.get('reg');
            Boolean attended = (String) ar.get('st') == CaptureConstants.ATTENDANCE_ATTENDED;
            if (reg) {
                s.registered += n;
                if (attended) {
                    s.checkedIn += n;
                } else {
                    s.notArrived += n;
                }
            } else if (attended) {
                s.walkIns += n;
            }
        }
        s.inProgress = [
            SELECT COUNT()
            FROM Capture__c
            WHERE
                Event__c = :ev.Id
                AND Channel__c = :CaptureConstants.CHANNEL_REGISTRATION
                AND Matching_Status__c IN (:CaptureConstants.MATCH_QUEUED, :CaptureConstants.MATCH_REVIEW)
        ];
        s.notFound = [
            SELECT COUNT()
            FROM Capture__c
            WHERE
                Event__c = :ev.Id
                AND Channel__c = :CaptureConstants.CHANNEL_REGISTRATION
                AND Match_Rule__c = :CaptureConstants.RULE_REGISTRATION_NOT_FOUND
        ];
        return s;
    }

    // ------------------------------------------------------------ import

    @AuraEnabled
    public static ImportResult importRegistrations(String eventId, List<Registrant> rows) {
        if (!FeatureManagement.checkPermission(CaptureConstants.PERM_STEWARD)) {
            throw new AuraHandledException('Only admins and data stewards can import registrations.');
        }
        Event__c ev = loadEvent(eventId);
        if (rows == null || rows.isEmpty()) {
            throw new AuraHandledException('The file has no registrations.');
        }
        if (rows.size() > MAX_ROWS) {
            throw new AuraHandledException('At most ' + MAX_ROWS + ' registrations per import. Split the file.');
        }
        return register(ev.Id, rows);
    }

    /** Creates one registration capture per new row. Re-importing the same file skips the rows already imported. */
    public static ImportResult register(Id eventId, List<Registrant> rows) {
        ImportResult result = new ImportResult();
        ConsentCaptureConfig.ConsentText text = ConsentCaptureConfig.activeConsentText();
        Set<String> specialties = new Set<String>(ConsentCaptureConfig.specialties());

        Set<String> seen = new Set<String>();
        for (Capture__c c : [
            SELECT Email__c, First_Name__c, Last_Name__c
            FROM Capture__c
            WHERE Event__c = :eventId AND Channel__c = :CaptureConstants.CHANNEL_REGISTRATION
            LIMIT 10000
        ]) {
            seen.add(rowKey(c.Email__c, c.First_Name__c, c.Last_Name__c));
        }

        List<Capture__c> captures = new List<Capture__c>();
        Integer line = 1;
        for (Registrant r : rows) {
            line++;
            String first = clean(r.firstName, 80);
            String last = clean(r.lastName, 80);
            String email = clean(r.email, 80);
            if (String.isBlank(first) || String.isBlank(last)) {
                result.skipped++;
                addMessage(result, 'Row ' + line + ': first and last name are required.');
                continue;
            }
            if (String.isNotBlank(email) && !EMAIL_PATTERN.matcher(email).matches()) {
                result.skipped++;
                addMessage(result, 'Row ' + line + ': email "' + email + '" is not valid.');
                continue;
            }
            String key = rowKey(email, first, last);
            if (seen.contains(key)) {
                result.skipped++;
                addMessage(result, 'Row ' + line + ': ' + first + ' ' + last + ' is already registered (skipped).');
                continue;
            }
            seen.add(key);

            String specialty = clean(r.specialty, 255);
            Boolean consent = r.consent == true;
            Datetime registeredAt = parseDate(r.consentDate);
            String version = clean(r.consentVersion, 20);
            captures.add(
                new Capture__c(
                    Event__c = eventId,
                    Channel__c = CaptureConstants.CHANNEL_REGISTRATION,
                    First_Name__c = first,
                    Last_Name__c = last,
                    Email__c = String.isBlank(email) ? null : email.toLowerCase(),
                    Specialty__c = specialties.contains(specialty) ? specialty : null,
                    City__c = clean(r.city, 80),
                    Registration_Number__c = clean(r.registrationNumber, 30),
                    Organisation__c = clean(r.organisation, 255),
                    Captured_At__c = registeredAt,
                    Captured_By_Name__c = IMPORTED_BY,
                    Consent_Given__c = consent,
                    Consent_Method__c = consent ? CaptureConstants.METHOD_REGISTRATION : null,
                    Opt_In_Status__c = consent ? CaptureConstants.OPTIN_CONFIRMED : null,
                    Opt_In_Confirmed_At__c = consent ? registeredAt : null,
                    Consent_Text_Version__c = consent ? (String.isBlank(version) ? text.version : version) : null,
                    Send_Slides__c = false,
                    Confirmation_Email_Status__c = CaptureConstants.EMAIL_NOT_REQUIRED,
                    Processing_Stage__c = CaptureConstants.STAGE_RECEIVED,
                    Matching_Status__c = CaptureConstants.MATCH_QUEUED
                )
            );
        }
        if (captures.isEmpty()) {
            return result;
        }
        List<Database.SaveResult> saved = Database.insert(captures, false);
        for (Integer i = 0; i < saved.size(); i++) {
            if (saved[i].isSuccess()) {
                result.imported++;
            } else {
                result.skipped++;
                addMessage(
                    result,
                    captures[i].First_Name__c + ' ' + captures[i].Last_Name__c + ': ' + saved[i].getErrors()[0].getMessage()
                );
            }
        }
        return result;
    }

    // ------------------------------------------------------------ helpers

    private static Event__c loadEvent(String eventId) {
        Id evId;
        try {
            evId = Id.valueOf(eventId);
        } catch (Exception e) {
            throw new AuraHandledException('Event not found.');
        }
        List<Event__c> rows = [SELECT Id, Name FROM Event__c WHERE Id = :evId LIMIT 1];
        if (rows.isEmpty()) {
            throw new AuraHandledException('Event not found.');
        }
        return rows[0];
    }

    private static String rowKey(String email, String first, String last) {
        if (String.isNotBlank(email)) {
            return 'e:' + email.trim().toLowerCase();
        }
        return 'n:' + HcpMatchEngine.normalizeName(first) + '|' + HcpMatchEngine.normalizeName(last);
    }

    @TestVisible
    private static Datetime parseDate(String value) {
        if (String.isBlank(value)) {
            return System.now();
        }
        try {
            Date d = Date.valueOf(value.trim().left(10));
            return Datetime.newInstanceGmt(d.year(), d.month(), d.day(), 12, 0, 0);
        } catch (Exception e) {
            return System.now();
        }
    }

    private static String clean(String value, Integer maxLength) {
        if (value == null) {
            return null;
        }
        String v = value.replaceAll('[\\p{Cntrl}<>]', ' ').normalizeSpace();
        return String.isBlank(v) ? null : v.left(maxLength);
    }

    private static void addMessage(ImportResult result, String message) {
        if (result.messages.size() < 50) {
            result.messages.add(message);
        }
    }
}
