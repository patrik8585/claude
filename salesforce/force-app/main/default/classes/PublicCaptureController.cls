/**
 * Apex behind the PUBLIC capture page (Experience Cloud guest user): QR self-scan,
 * kiosk mode and the double opt-in confirmation page.
 *
 * Security model:
 *  - without sharing on purpose: the guest user has NO object permissions; this class is the only door.
 *  - every input is validated server-side (lengths, email format, specialty picklist, event state);
 *  - channel is derived from the mode, never trusted from the client;
 *  - bot protection: honeypot field + HMAC-signed form token with minimum fill time + rate limits;
 *  - no record Ids or other HCP data are ever returned to the browser;
 *  - captures are re-owned by the event owner during matching (no guest-owned records).
 */
public without sharing class PublicCaptureController {
    private static final String GENERIC_ERROR = 'Sorry, we could not save your registration. Please ask a Danone representative.';
    private static final Pattern EMAIL_PATTERN = Pattern.compile('^[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}$');
    private static final Pattern REG_PATTERN = Pattern.compile('^[A-Za-z0-9 /\\-]{0,30}$');
    private static final Long MAX_FORM_AGE_MS = 4L * 60 * 60 * 1000;

    public class FormContext {
        @AuraEnabled
        public String eventName;
        @AuraEnabled
        public String eventShortName;
        @AuraEnabled
        public String eventDates;
        @AuraEnabled
        public String eventType;
        @AuraEnabled
        public String location;
        @AuraEnabled
        public String consentText;
        @AuraEnabled
        public String consentVersion;
        @AuraEnabled
        public String formToken;
        @AuraEnabled
        public List<String> specialties;
    }

    public class Submission {
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
        public Boolean consent { get; set; }
        @AuraEnabled
        public Boolean sendSlides { get; set; }
        /** Honeypot: hidden field that humans never fill. */
        @AuraEnabled
        public String website { get; set; }
    }

    public class SubmitResult {
        @AuraEnabled
        public Boolean success;
        @AuraEnabled
        public String message;
        @AuraEnabled
        public String firstName;
        @AuraEnabled
        public String email;
        @AuraEnabled
        public String nextFormToken;
    }

    public class ConfirmationView {
        /** valid | confirmed | expired | invalid */
        @AuraEnabled
        public String status;
        @AuraEnabled
        public String lastName;
        @AuraEnabled
        public String eventName;
        @AuraEnabled
        public String consentText;
        @AuraEnabled
        public String consentVersion;
        @AuraEnabled
        public String slidesUrl;
        @AuraEnabled
        public String confirmedOn;
    }

    // ------------------------------------------------------------ form

    @AuraEnabled
    public static FormContext getFormContext(String eventId) {
        Event__c ev = loadPublicEvent(eventId);
        if (ev == null) {
            throw new AuraHandledException('This registration page is not available.');
        }
        ConsentCaptureConfig.ConsentText text = ConsentCaptureConfig.activeConsentText();
        FormContext ctx = new FormContext();
        ctx.eventName = ev.Name;
        ctx.eventShortName = String.isBlank(ev.Short_Name__c) ? ev.Name : ev.Short_Name__c;
        ctx.eventDates = formatDates(ev.Start_Date__c, ev.End_Date__c);
        ctx.eventType = ev.Event_Type__c;
        ctx.location = ev.Location__c;
        ctx.consentText = text.body;
        ctx.consentVersion = text.version;
        ctx.specialties = ConsentCaptureConfig.specialties();
        try {
            ctx.formToken = issueFormToken(ev.Id);
        } catch (ConsentCaptureConfig.ConfigException e) {
            throw new AuraHandledException('This registration page is not configured yet.');
        }
        return ctx;
    }

    @AuraEnabled
    public static SubmitResult submitCapture(String eventId, String mode, String formToken, Submission submission) {
        SubmitResult result = new SubmitResult();
        result.success = false;
        Event__c ev = loadPublicEvent(eventId);
        if (ev == null || submission == null) {
            result.message = GENERIC_ERROR;
            return result;
        }
        // Bot checks: silently "succeed" for honeypot hits so bots learn nothing.
        if (String.isNotBlank(submission.website)) {
            result.success = true;
            result.firstName = clean(submission.firstName, 80);
            result.email = clean(submission.email, 80);
            result.nextFormToken = safeIssue(ev.Id);
            return result;
        }
        if (!verifyFormToken(formToken, ev.Id)) {
            result.message = 'This page has expired. Please reload it and try again.';
            result.nextFormToken = safeIssue(ev.Id);
            return result;
        }

        String firstName = clean(submission.firstName, 80);
        String lastName = clean(submission.lastName, 80);
        String email = clean(submission.email, 80);
        String specialty = clean(submission.specialty, 255);
        String city = clean(submission.city, 80);
        String reg = clean(submission.registrationNumber, 30);
        List<String> errors = new List<String>();
        if (String.isBlank(firstName)) {
            errors.add('first name');
        }
        if (String.isBlank(lastName)) {
            errors.add('last name');
        }
        if (String.isBlank(email) || !EMAIL_PATTERN.matcher(email).matches()) {
            errors.add('work email');
        }
        if (String.isBlank(specialty) || !ConsentCaptureConfig.specialties().contains(specialty)) {
            errors.add('specialty');
        }
        if (String.isBlank(city)) {
            errors.add('city');
        }
        if (String.isNotBlank(reg) && !REG_PATTERN.matcher(reg).matches()) {
            errors.add('registration number');
        }
        if (submission.consent != true) {
            errors.add('consent');
        }
        if (!errors.isEmpty()) {
            result.message = 'Please complete: ' + String.join(errors, ', ') + '.';
            result.nextFormToken = safeIssue(ev.Id);
            return result;
        }

        String limitMessage = checkRateLimits(ev.Id, email);
        if (limitMessage != null) {
            result.message = limitMessage;
            result.nextFormToken = safeIssue(ev.Id);
            return result;
        }

        ConsentCaptureConfig.ConsentText text = ConsentCaptureConfig.activeConsentText();
        Boolean kiosk = 'kiosk'.equalsIgnoreCase(mode);
        Capture__c capture = new Capture__c(
            First_Name__c = firstName,
            Last_Name__c = lastName,
            Email__c = email.toLowerCase(),
            Specialty__c = specialty,
            City__c = city,
            Registration_Number__c = reg,
            Channel__c = kiosk ? CaptureConstants.CHANNEL_KIOSK : CaptureConstants.CHANNEL_SELF,
            Event__c = ev.Id,
            Captured_At__c = System.now(),
            Consent_Given__c = true,
            Consent_Method__c = CaptureConstants.METHOD_EMAIL,
            Opt_In_Status__c = CaptureConstants.OPTIN_PENDING,
            Consent_Text_Version__c = text.version,
            Send_Slides__c = submission.sendSlides == true,
            Processing_Stage__c = CaptureConstants.STAGE_RECEIVED,
            Matching_Status__c = CaptureConstants.MATCH_QUEUED
        );
        String token = ConsentService.attachNewToken(capture);
        try {
            insert capture;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Public capture insert failed: ' + e.getMessage());
            result.message = GENERIC_ERROR;
            return result;
        }
        Boolean sent = ConsentService.sendConfirmationEmail(email, lastName, ev.Name, token);
        update new Capture__c(
            Id = capture.Id,
            Confirmation_Email_Status__c = sent ? CaptureConstants.EMAIL_SENT : CaptureConstants.EMAIL_FAILED
        );

        result.success = true;
        result.firstName = firstName;
        result.email = email;
        result.nextFormToken = safeIssue(ev.Id);
        return result;
    }

    // ------------------------------------------------------------ double opt-in

    @AuraEnabled
    public static ConfirmationView getConfirmation(String token) {
        return view(ConsentService.findByToken(token));
    }

    @AuraEnabled
    public static ConfirmationView confirm(String token) {
        Capture__c capture = ConsentService.findByToken(token);
        ConfirmationView v = view(capture);
        if (v.status != 'valid') {
            return v;
        }
        ConsentService.confirm(capture);
        return view(capture);
    }

    private static ConfirmationView view(Capture__c capture) {
        ConfirmationView v = new ConfirmationView();
        if (capture == null) {
            v.status = 'invalid';
            return v;
        }
        ConsentCaptureConfig.ConsentText text = ConsentCaptureConfig.activeConsentText();
        v.lastName = capture.Last_Name__c;
        v.eventName = capture.Event__r == null ? null : capture.Event__r.Name;
        v.consentVersion = String.isBlank(capture.Consent_Text_Version__c) ? text.version : capture.Consent_Text_Version__c;
        v.consentText = text.body;
        if (capture.Opt_In_Status__c == CaptureConstants.OPTIN_CONFIRMED) {
            v.status = 'confirmed';
            v.confirmedOn = capture.Opt_In_Confirmed_At__c == null ? null : capture.Opt_In_Confirmed_At__c.format('d MMM yyyy');
            if (capture.Send_Slides__c && capture.Event__r != null) {
                v.slidesUrl = capture.Event__r.Slides_Url__c;
            }
        } else if (capture.Token_Expires_At__c != null && capture.Token_Expires_At__c < System.now()) {
            v.status = 'expired';
        } else if (capture.Opt_In_Status__c == CaptureConstants.OPTIN_PENDING) {
            v.status = 'valid';
        } else {
            v.status = 'invalid';
        }
        return v;
    }

    // ------------------------------------------------------------ helpers

    private static Event__c loadPublicEvent(String eventId) {
        Id evId;
        try {
            evId = Id.valueOf(eventId);
        } catch (Exception e) {
            return null;
        }
        if (evId.getSobjectType() != Event__c.SObjectType) {
            return null;
        }
        List<Event__c> rows = [
            SELECT Id, Name, Short_Name__c, Event_Type__c, Start_Date__c, End_Date__c, Location__c, Slides_Url__c
            FROM Event__c
            WHERE Id = :evId AND Active__c = TRUE AND Public_Capture_Enabled__c = TRUE
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    /** Trims, strips control characters and markup brackets, and caps the length. */
    @TestVisible
    private static String clean(String value, Integer maxLength) {
        if (value == null) {
            return null;
        }
        String v = value.replaceAll('[\\p{Cntrl}<>]', ' ').normalizeSpace();
        return v.left(maxLength);
    }

    private static String checkRateLimits(Id eventId, String email) {
        Datetime dayAgo = System.now().addHours(-24);
        Integer sameEmail = [
            SELECT COUNT()
            FROM Capture__c
            WHERE Email__c = :email AND Event__c = :eventId AND CreatedDate >= :dayAgo
        ];
        if (sameEmail >= ConsentCaptureConfig.maxPerEmailPerDay()) {
            return 'We have already received your registration. Please check your inbox.';
        }
        Datetime minuteAgo = System.now().addMinutes(-1);
        Integer lastMinute = [SELECT COUNT() FROM Capture__c WHERE Event__c = :eventId AND CreatedDate >= :minuteAgo];
        if (lastMinute >= ConsentCaptureConfig.maxPerEventPerMinute()) {
            return 'Many people are registering right now. Please try again in a minute.';
        }
        return null;
    }

    @TestVisible
    private static String issueFormToken(Id eventId) {
        String payload = String.valueOf(eventId) + '|' + String.valueOf(System.currentTimeMillis());
        return payload + '|' + sign(payload);
    }

    private static String safeIssue(Id eventId) {
        try {
            return issueFormToken(eventId);
        } catch (Exception e) {
            return null;
        }
    }

    @TestVisible
    private static Boolean verifyFormToken(String token, Id eventId) {
        if (String.isBlank(token)) {
            return false;
        }
        List<String> parts = token.split('\\|');
        if (parts.size() != 3 || !parts[0].equals(String.valueOf(eventId))) {
            return false;
        }
        String expected;
        try {
            expected = sign(parts[0] + '|' + parts[1]);
        } catch (Exception e) {
            return false;
        }
        if (!expected.equals(parts[2])) {
            return false;
        }
        Long issued;
        try {
            issued = Long.valueOf(parts[1]);
        } catch (Exception e) {
            return false;
        }
        Long age = System.currentTimeMillis() - issued;
        return age >= ConsentCaptureConfig.minFormSeconds() * 1000L && age <= MAX_FORM_AGE_MS;
    }

    private static String sign(String payload) {
        Blob mac = Crypto.generateMac('hmacSHA256', Blob.valueOf(payload), Blob.valueOf(ConsentCaptureConfig.formSecret()));
        return EncodingUtil.base64Encode(mac);
    }

    private static final List<String> MONTHS = new List<String>{
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    };

    public static String formatDates(Date startDate, Date endDate) {
        if (startDate == null) {
            return '';
        }
        if (endDate == null || endDate == startDate) {
            return startDate.day() + ' ' + MONTHS[startDate.month() - 1] + ' ' + startDate.year();
        }
        if (startDate.month() == endDate.month() && startDate.year() == endDate.year()) {
            return startDate.day() + '–' + endDate.day() + ' ' + MONTHS[endDate.month() - 1] + ' ' + endDate.year();
        }
        return startDate.day() + ' ' + MONTHS[startDate.month() - 1] + ' – ' + endDate.day() + ' ' + MONTHS[endDate.month() - 1] + ' ' + endDate.year();
    }
}
