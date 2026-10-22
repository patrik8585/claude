/**
 * Parameters of the HCP matching engine, read from Custom Metadata Matching_Setting__mdt
 * (record "Default"). Every value has a built-in default, so matching still works when the
 * record or a field is empty. Edit the record in Setup > Custom Metadata Types > Matching Setting.
 */
public with sharing class MatchingConfig {
    public static final String RECORD_NAME = 'Default';

    /** Test hook: tests set this to try other parameters without deploying metadata. */
    @TestVisible
    private static Matching_Setting__mdt overrideRecord;

    private static MatchingConfig instance;

    public Integer wNameExact;
    public Integer wNameSwapped;
    public Integer wNameFuzzy;
    public Integer wSurnameOnly;
    public Integer wEmail;
    public Integer wEmailDomain;
    public Integer wRegistration;
    public Integer penaltyRegConflict;
    public Integer wDepartment;
    public Integer wHospital;
    public Integer wOrgText;
    public Integer wSpecialty;
    public Integer wCity;
    public Integer wRegistered;
    public Integer maxDistShort;
    public Integer maxDistLong;
    public Integer longNameLength;
    public Integer minCandidateScore;
    public Integer highConfidenceScore;
    public Integer highConfidenceGap;
    public Integer maxCandidates;
    public Boolean autoEmail;
    public Boolean autoRegistration;
    public Boolean reviewOnConflict;
    public Set<String> personalDomains;

    public static MatchingConfig get() {
        if (instance == null) {
            Matching_Setting__mdt rec = overrideRecord;
            if (rec == null) {
                rec = Matching_Setting__mdt.getInstance(RECORD_NAME);
            }
            instance = new MatchingConfig(rec);
        }
        return instance;
    }

    @TestVisible
    private static void reset() {
        instance = null;
    }

    private MatchingConfig(Matching_Setting__mdt r) {
        wNameExact = num(r, 'Weight_Name_Exact__c', 30);
        wNameSwapped = num(r, 'Weight_Name_Swapped__c', 25);
        wNameFuzzy = num(r, 'Weight_Name_Fuzzy__c', 20);
        wSurnameOnly = num(r, 'Weight_Surname_Only__c', 15);
        wEmail = num(r, 'Weight_Email__c', 20);
        wEmailDomain = num(r, 'Weight_Email_Domain__c', 5);
        wRegistration = num(r, 'Weight_Registration__c', 15);
        penaltyRegConflict = num(r, 'Penalty_Registration_Conflict__c', 20);
        wDepartment = num(r, 'Weight_Department__c', 15);
        wHospital = num(r, 'Weight_Hospital__c', 10);
        wOrgText = num(r, 'Weight_Organisation_Text__c', 5);
        wSpecialty = num(r, 'Weight_Specialty__c', 10);
        wCity = num(r, 'Weight_City__c', 10);
        wRegistered = num(r, 'Weight_Registered_Attendee__c', 10);
        maxDistShort = num(r, 'Max_Edit_Distance_Short__c', 1);
        maxDistLong = num(r, 'Max_Edit_Distance_Long__c', 2);
        longNameLength = num(r, 'Long_Name_Length__c', 7);
        minCandidateScore = num(r, 'Min_Candidate_Score__c', 15);
        highConfidenceScore = num(r, 'High_Confidence_Score__c', 60);
        highConfidenceGap = num(r, 'High_Confidence_Gap__c', 10);
        maxCandidates = Math.max(1, num(r, 'Max_Candidates__c', 10));
        // Checkboxes are never null on a record; without a record the safe defaults apply.
        autoEmail = r == null ? true : r.Auto_Match_Email__c;
        autoRegistration = r == null ? true : r.Auto_Match_Registration__c;
        reviewOnConflict = r == null ? true : r.Review_On_Conflict__c;
        String domains = r == null ? null : r.Personal_Email_Domains__c;
        if (String.isBlank(domains)) {
            domains = 'gmail.com,googlemail.com,yahoo.com,yahoo.it,hotmail.com,hotmail.it,outlook.com,outlook.it,live.it,libero.it,virgilio.it,icloud.com,me.com,tiscali.it,alice.it';
        }
        personalDomains = new Set<String>();
        for (String d : domains.split('[,;\\s]+')) {
            if (String.isNotBlank(d)) {
                personalDomains.add(d.trim().toLowerCase().removeStart('@'));
            }
        }
    }

    private static Integer num(Matching_Setting__mdt r, String field, Integer fallback) {
        if (r == null) {
            return fallback;
        }
        Object v = r.get(field);
        return v == null ? fallback : ((Decimal) v).intValue();
    }

    /** Allowed Levenshtein distance for a normalised name. */
    public Integer maxDistance(String normalisedName) {
        return normalisedName.length() >= longNameLength ? maxDistLong : maxDistShort;
    }

    public Boolean isPersonalDomain(String domain) {
        return String.isBlank(domain) || personalDomains.contains(domain.toLowerCase());
    }
}
