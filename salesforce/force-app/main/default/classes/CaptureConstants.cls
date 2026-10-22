/**
 * Picklist values and labels shared by the HCP consent capture classes.
 * Keep in sync with the picklist field metadata.
 */
public with sharing class CaptureConstants {
    // Capture__c.Channel__c / Consent__c.Channel__c
    public static final String CHANNEL_SELF = 'Self-scan';
    public static final String CHANNEL_REP = 'Rep';
    public static final String CHANNEL_KIOSK = 'Kiosk';
    public static final String CHANNEL_PITCHER = 'Pitcher';
    /** Imported pre-event registration (not an event-day capture). */
    public static final String CHANNEL_REGISTRATION = 'Event registration';

    // Capture__c.Consent_Method__c
    public static final String METHOD_EMAIL = 'Email double opt-in';
    public static final String METHOD_SIGNATURE = 'Explicit question + signature';
    public static final String METHOD_EXISTING = 'Existing consent reused';
    public static final String METHOD_DECLINED = 'Declined';
    public static final String METHOD_REGISTRATION = 'Given at event registration';
    /** Match rule of a registration that matches no HCP: only HCPs already in Salesforce can be registered. */
    public static final String RULE_REGISTRATION_NOT_FOUND = 'Registration - HCP not in Salesforce';
    // Event_Attendee__c.Attendance_Status__c
    public static final String ATTENDANCE_REGISTERED = 'Registered';
    public static final String ATTENDANCE_ATTENDED = 'Attended';
    // Consent__c.Opt_In_Method__c (legacy records)
    public static final String METHOD_PITCHER = 'Pitcher (legacy)';

    // Capture__c.Opt_In_Status__c
    public static final String OPTIN_PENDING = 'Pending';
    public static final String OPTIN_CONFIRMED = 'Confirmed';
    public static final String OPTIN_DECLINED = 'Declined';

    // Capture__c.Processing_Stage__c
    public static final String STAGE_RECEIVED = 'Received';
    public static final String STAGE_TO_REVIEW = 'To review';
    public static final String STAGE_MATCHED = 'Matched';
    public static final String STAGE_CONSENT_CREATED = 'Consent created';
    public static final String STAGE_SENT = 'Sent to Gigya';
    public static final String STAGE_NO_CONSENT = 'Completed - no consent';
    public static final String STAGE_DISCARDED = 'Discarded';
    public static final String STAGE_ERROR = 'Error';

    // Capture__c.Matching_Status__c
    public static final String MATCH_QUEUED = 'Queued';
    public static final String MATCH_AUTO = 'Auto-matched';
    public static final String MATCH_REVIEW = 'To review';
    public static final String MATCH_NEW = 'New HCP';
    public static final String MATCH_REVIEWED = 'Reviewed - matched';
    public static final String MATCH_REVIEWED_NEW = 'Reviewed - new HCP';
    public static final String MATCH_DISCARDED = 'Discarded';
    public static final String MATCH_ERROR = 'Error';

    // Consent__c.Status__c
    public static final String CONSENT_PENDING = 'Pending double opt-in';
    public static final String CONSENT_CONFIRMED = 'Opt-in confirmed';
    public static final String CONSENT_WITHDRAWN = 'Withdrawn';
    public static final String CONSENT_TYPE_EMAIL = 'Email - scientific & promotional communications';

    // Consent__c.Gigya_Status__c
    public static final String GIGYA_WAITING = 'Not sent - waiting for opt-in';
    public static final String GIGYA_QUEUED = 'Queued';
    public static final String GIGYA_SENT = 'Sent';
    public static final String GIGYA_ERROR = 'Error';

    // Contact.Consent_Status__c
    public static final String HCP_NONE = 'None';
    public static final String HCP_PENDING = 'Pending';
    public static final String HCP_OPTIN = 'Opt-in';
    public static final String HCP_OPTOUT = 'Opted out';

    // Capture_Candidate__c.*_Match__c
    public static final String FLAG_EXACT = 'Exact';
    public static final String FLAG_PARTIAL = 'Partial';
    public static final String FLAG_NONE = 'None';
    public static final String FLAG_NA = 'Not captured';

    // Capture__c.Confirmation_Email_Status__c
    public static final String EMAIL_NOT_REQUIRED = 'Not required';
    public static final String EMAIL_SENT = 'Sent';
    public static final String EMAIL_FAILED = 'Failed';

    // Custom permissions
    public static final String PERM_REP = 'HCP_Capture_Rep';
    public static final String PERM_STEWARD = 'HCP_Capture_Data_Steward';

    public static final String UNKNOWN_ORGANISATION = 'HCPs - organisation unknown';
}
