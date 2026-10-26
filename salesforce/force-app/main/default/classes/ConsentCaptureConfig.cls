/**
 * Reads Consent_Capture_Settings__c (hierarchy custom setting) and the active
 * Consent_Text__mdt record, with safe defaults.
 */
public without sharing class ConsentCaptureConfig {
    public static final String DEFAULT_VERSION = 'v3.2';
    public static final String DEFAULT_TEXT = 'I agree that Danone may send me scientific information, product news and invitations to events by email. I can withdraw my consent at any time using the link in every email. See the Privacy Notice for details.';
    public static final String DEFAULT_QUESTION = 'May we send you scientific information and product news by email? You can withdraw at any time.';

    public class ConfigException extends Exception {
    }

    public class ConsentText {
        @AuraEnabled
        public String version;
        @AuraEnabled
        public String body;
        @AuraEnabled
        public String question;
    }

    @TestVisible
    private static Consent_Capture_Settings__c cached;

    /** Forces the next settings() call to re-read the custom setting. */
    public static void resetCache() {
        cached = null;
    }

    public static Consent_Capture_Settings__c settings() {
        if (cached == null) {
            cached = Consent_Capture_Settings__c.getOrgDefaults();
            if (cached == null) {
                cached = new Consent_Capture_Settings__c();
            }
        }
        return cached;
    }

    private static Integer intOr(Decimal value, Integer fallback) {
        return value == null ? fallback : value.intValue();
    }

    public static Integer maxPerEmailPerDay() {
        return intOr(settings().Max_Per_Email_Per_Day__c, 3);
    }

    public static Integer maxPerEventPerMinute() {
        return intOr(settings().Max_Per_Event_Per_Minute__c, 30);
    }

    public static Integer minFormSeconds() {
        return intOr(settings().Min_Form_Seconds__c, 3);
    }

    public static Integer tokenValidityDays() {
        return intOr(settings().Token_Validity_Days__c, 30);
    }

    public static String publicSiteUrl() {
        return settings().Public_Site_Url__c;
    }

    public static String formSecret() {
        String secret = settings().Form_Secret__c;
        if (String.isBlank(secret)) {
            throw new ConfigException('Consent_Capture_Settings__c.Form_Secret__c is not set. Run ConsentDemoData.configure().');
        }
        return secret;
    }

    public static ConsentText activeConsentText() {
        ConsentText result = new ConsentText();
        result.version = DEFAULT_VERSION;
        result.body = DEFAULT_TEXT;
        result.question = DEFAULT_QUESTION;
        Consent_Text__mdt best;
        for (Consent_Text__mdt t : Consent_Text__mdt.getAll().values()) {
            if (t.Active__c && String.isNotBlank(t.Version__c) && (best == null || t.Version__c > best.Version__c)) {
                best = t;
            }
        }
        if (best != null) {
            result.version = best.Version__c;
            result.body = String.isBlank(best.Body__c) ? DEFAULT_TEXT : best.Body__c;
            result.question = String.isBlank(best.Question__c) ? DEFAULT_QUESTION : best.Question__c;
        }
        return result;
    }

    public static List<String> specialties() {
        List<String> values = new List<String>();
        for (Schema.PicklistEntry e : Capture__c.Specialty__c.getDescribe().getPicklistValues()) {
            if (e.isActive()) {
                values.add(e.getValue());
            }
        }
        return values;
    }

    /** Therapeutic areas the rep can tick on the Rep Hub (optional, several allowed). */
    public static List<String> therapeuticAreas() {
        List<String> values = new List<String>();
        for (Schema.PicklistEntry e : Capture__c.Therapeutic_Area__c.getDescribe().getPicklistValues()) {
            if (e.isActive()) {
                values.add(e.getValue());
            }
        }
        return values;
    }
}
