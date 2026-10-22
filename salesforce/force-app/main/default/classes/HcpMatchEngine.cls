/**
 * Deterministic, explainable comparison of two HCP profiles. Used by capture matching
 * (capture vs. existing Contact).
 *
 * Every rule that fires adds (or subtracts) the points configured in Matching_Setting__mdt
 * and one line to the explanation, so a steward always sees why a candidate was proposed.
 *
 * Name similarity: accent-insensitive normalisation (Nicolò = Nicolo), swapped first/last
 * name, and String.getLevenshteinDistance with a maximum distance per name length.
 */
public with sharing class HcpMatchEngine {
    public static final String NAME_EXACT = 'identical';
    public static final String NAME_SWAPPED = 'swapped';
    public static final String NAME_FUZZY = 'similar';
    public static final String NAME_SURNAME = 'surname';
    public static final String NAME_NONE = 'none';

    public class Profile {
        public Id recordId;
        public String firstName;
        public String lastName;
        public String email;
        public String registrationNumber;
        public String specialty;
        public String city;
        /** Free text (capture) or Account name (Contact). */
        public String organisation;
        public Set<Id> hospitalIds = new Set<Id>();
        public Set<Id> departmentIds = new Set<Id>();
        public Contact contact;

        public String nFirst;
        public String nLast;
        public String nEmail;
        public String domain;
        public String regKey;
        private Boolean prepared = false;

        public void prepare() {
            if (prepared) {
                return;
            }
            nFirst = HcpMatchEngine.normalizeName(firstName);
            nLast = HcpMatchEngine.normalizeName(lastName);
            nEmail = String.isBlank(email) ? '' : email.trim().toLowerCase();
            domain = HcpMatchEngine.emailDomain(email);
            regKey = HcpMatchEngine.registrationKey(registrationNumber);
            prepared = true;
        }
    }

    public class Comparison {
        public Profile other;
        public String nameKind;
        public String nameFlag;
        public String emailFlag;
        public String specialtyFlag;
        public String cityFlag;
        public String orgFlag;
        public String regFlag;
        public Integer score = 0;
        public Boolean emailIdentical = false;
        public Boolean regIdentical = false;
        public Boolean regConflict = false;
        public List<String> explanation = new List<String>();
        /** Shared department or hospital, for the suggestion text. */
        public String sharedHco;

        public String explanationText() {
            return String.join(explanation, '\n').left(2000);
        }

        /** Proposed to a person when a name signal or an identical identifier exists and the score is high enough. */
        public Boolean isCandidate() {
            if (emailIdentical || regIdentical) {
                return true;
            }
            return nameKind != HcpMatchEngine.NAME_NONE && score >= MatchingConfig.get().minCandidateScore;
        }

        public void add(Integer points, String reason) {
            score += points;
            explanation.add((points >= 0 ? '+' : '') + points + ' ' + reason);
        }

        public void info(String reason) {
            explanation.add('0 ' + reason);
        }
    }

    // ------------------------------------------------------------ comparison

    /** Compares a (the capture, or the first HCP) with b (an existing HCP). Flags describe a as seen against b. */
    public static Comparison compare(Profile a, Profile b) {
        MatchingConfig cfg = MatchingConfig.get();
        HcoDirectory dir = HcoDirectory.get();
        a.prepare();
        b.prepare();
        Comparison c = new Comparison();
        c.other = b;

        // --- name
        c.nameKind = nameKind(a, b, cfg);
        if (c.nameKind == NAME_EXACT) {
            c.nameFlag = CaptureConstants.FLAG_EXACT;
            c.add(cfg.wNameExact, 'full name identical');
        } else if (c.nameKind == NAME_SWAPPED) {
            c.nameFlag = CaptureConstants.FLAG_PARTIAL;
            c.add(cfg.wNameSwapped, 'first and last name swapped');
        } else if (c.nameKind == NAME_FUZZY) {
            c.nameFlag = CaptureConstants.FLAG_PARTIAL;
            c.add(cfg.wNameFuzzy, 'name similar (' + display(a) + ' / ' + display(b) + ')');
        } else if (c.nameKind == NAME_SURNAME) {
            c.nameFlag = CaptureConstants.FLAG_PARTIAL;
            c.add(cfg.wSurnameOnly, 'same surname, different first name');
        } else {
            c.nameFlag = String.isBlank(a.nLast) ? CaptureConstants.FLAG_NA : CaptureConstants.FLAG_NONE;
        }

        // --- email
        if (String.isBlank(a.nEmail)) {
            c.emailFlag = CaptureConstants.FLAG_NA;
        } else if (a.nEmail == b.nEmail) {
            c.emailFlag = CaptureConstants.FLAG_EXACT;
            c.emailIdentical = true;
            c.add(cfg.wEmail, 'email identical');
        } else if (String.isNotBlank(a.domain) && a.domain == b.domain && !cfg.isPersonalDomain(a.domain)) {
            c.emailFlag = CaptureConstants.FLAG_PARTIAL;
            c.add(cfg.wEmailDomain, 'same institutional email domain (' + a.domain + ')');
        } else {
            c.emailFlag = CaptureConstants.FLAG_NONE;
            if (String.isNotBlank(b.nEmail)) {
                Boolean aPersonal = cfg.isPersonalDomain(a.domain);
                Boolean bPersonal = cfg.isPersonalDomain(b.domain);
                c.info(aPersonal != bPersonal ? 'email differs (personal vs. institutional address)' : 'email differs');
            }
        }

        // --- registration number
        if (String.isBlank(a.regKey)) {
            c.regFlag = CaptureConstants.FLAG_NA;
        } else if (String.isBlank(b.regKey)) {
            c.regFlag = CaptureConstants.FLAG_NONE;
            c.info('existing HCP has no registration number');
        } else if (a.regKey == b.regKey) {
            c.regFlag = CaptureConstants.FLAG_EXACT;
            c.regIdentical = true;
            c.add(cfg.wRegistration, 'registration number identical');
        } else if (registrationDigits(a.regKey) == registrationDigits(b.regKey) && (isDigitsOnly(a.regKey) || isDigitsOnly(b.regKey))) {
            c.regFlag = CaptureConstants.FLAG_PARTIAL;
            c.add(cfg.wRegistration / 2, 'registration number matches without province code');
        } else {
            c.regFlag = CaptureConstants.FLAG_NONE;
            c.regConflict = true;
            c.add(-cfg.penaltyRegConflict, 'registration numbers differ (' + a.regKey + ' / ' + b.regKey + ')');
        }

        // --- hospital / department
        Set<Id> sharedDepartments = new Set<Id>(a.departmentIds);
        sharedDepartments.retainAll(b.departmentIds);
        Set<Id> sharedHospitals = new Set<Id>(a.hospitalIds);
        sharedHospitals.retainAll(b.hospitalIds);
        if (!sharedDepartments.isEmpty()) {
            c.orgFlag = CaptureConstants.FLAG_EXACT;
            c.sharedHco = dir.label(new List<Id>(sharedDepartments)[0]);
            c.add(cfg.wDepartment, 'same department (' + c.sharedHco + ')');
        } else if (!sharedHospitals.isEmpty()) {
            c.orgFlag = CaptureConstants.FLAG_PARTIAL;
            c.sharedHco = dir.hospitalName(new List<Id>(sharedHospitals)[0]);
            c.add(cfg.wHospital, 'same hospital (' + c.sharedHco + ')');
        } else if (a.hospitalIds.isEmpty() && String.isBlank(a.organisation)) {
            c.orgFlag = CaptureConstants.FLAG_NA;
        } else if (a.hospitalIds.isEmpty() && orgTextSimilar(a.organisation, b)) {
            c.orgFlag = CaptureConstants.FLAG_PARTIAL;
            c.add(cfg.wOrgText, 'organisation text similar to ' + b.organisation);
        } else {
            c.orgFlag = CaptureConstants.FLAG_NONE;
            if (!a.hospitalIds.isEmpty() && !b.hospitalIds.isEmpty()) {
                c.info('different hospital');
            }
        }

        // --- specialty, city
        c.specialtyFlag = flag(a.specialty, b.specialty);
        if (c.specialtyFlag == CaptureConstants.FLAG_EXACT) {
            c.add(cfg.wSpecialty, 'same specialty');
        }
        c.cityFlag = flag(a.city, b.city);
        if (c.cityFlag == CaptureConstants.FLAG_EXACT) {
            c.add(cfg.wCity, 'same city');
        }

        c.score = Math.max(0, Math.min(100, c.score));
        return c;
    }

    private static String nameKind(Profile a, Profile b, MatchingConfig cfg) {
        if (String.isBlank(a.nLast) || String.isBlank(b.nLast)) {
            return NAME_NONE;
        }
        Boolean firstKnown = String.isNotBlank(a.nFirst) && String.isNotBlank(b.nFirst);
        Boolean lastEq = a.nLast == b.nLast;
        if (lastEq && firstKnown && a.nFirst == b.nFirst) {
            return NAME_EXACT;
        }
        if (firstKnown && a.nFirst == b.nLast && a.nLast == b.nFirst) {
            return NAME_SWAPPED;
        }
        if (firstKnown && close(a.nLast, b.nLast, cfg) && firstCompatible(a.nFirst, b.nFirst, cfg)) {
            return NAME_FUZZY;
        }
        if (firstKnown && close(a.nFirst, b.nLast, cfg) && close(a.nLast, b.nFirst, cfg)) {
            return NAME_SWAPPED;
        }
        return lastEq ? NAME_SURNAME : NAME_NONE;
    }

    /** True when the two normalised names are within the allowed edit distance (names of 3+ characters). */
    public static Boolean close(String x, String y, MatchingConfig cfg) {
        if (x == y) {
            return true;
        }
        if (x.length() < 3 || y.length() < 3) {
            return false;
        }
        Integer maxDist = cfg.maxDistance(x.length() <= y.length() ? x : y);
        if (maxDist <= 0 || Math.abs(x.length() - y.length()) > maxDist) {
            return false;
        }
        if (isTransposition(x, y)) {
            return true;
        }
        Integer d = x.getLevenshteinDistance(y, maxDist);
        return d >= 0 && d <= maxDist;
    }

    /** Two adjacent letters swapped ("Csota" / "Costa") counts as one typing error (Levenshtein counts 2). */
    public static Boolean isTransposition(String x, String y) {
        if (x.length() != y.length()) {
            return false;
        }
        Integer first = -1;
        for (Integer i = 0; i < x.length(); i++) {
            if (x.charAt(i) != y.charAt(i)) {
                first = i;
                break;
            }
        }
        if (first < 0 || first + 1 >= x.length()) {
            return false;
        }
        return x.charAt(first) == y.charAt(first + 1) && x.charAt(first + 1) == y.charAt(first) &&
            x.substring(first + 2) == y.substring(first + 2);
    }

    /** Similar first names, or an initial ("M" / "Maria"). */
    private static Boolean firstCompatible(String x, String y, MatchingConfig cfg) {
        if (close(x, y, cfg)) {
            return true;
        }
        return (x.length() == 1 && y.startsWith(x)) || (y.length() == 1 && x.startsWith(y));
    }

    private static Boolean orgTextSimilar(String organisation, Profile b) {
        String o = normalize(organisation);
        String h = normalize(b.organisation);
        return o.length() >= 4 && String.isNotBlank(h) && (h.contains(o) || o.contains(h));
    }

    private static String flag(String captured, String existing) {
        if (String.isBlank(captured)) {
            return CaptureConstants.FLAG_NA;
        }
        return normalize(captured) == normalize(existing) ? CaptureConstants.FLAG_EXACT : CaptureConstants.FLAG_NONE;
    }

    private static String display(Profile p) {
        return ((p.firstName == null ? '' : p.firstName + ' ') + (p.lastName == null ? '' : p.lastName)).trim();
    }

    // ------------------------------------------------------------ profiles

    public static Profile fromCapture(Capture__c c) {
        Profile p = new Profile();
        p.recordId = c.Id;
        p.firstName = c.First_Name__c;
        p.lastName = c.Last_Name__c;
        p.email = c.Email__c;
        p.registrationNumber = c.Registration_Number__c;
        p.specialty = c.Specialty__c;
        p.city = c.City__c;
        p.organisation = c.Organisation__c;
        HcoDirectory dir = HcoDirectory.get();
        if (c.Department__c != null) {
            p.departmentIds.add(c.Department__c);
            Id h = dir.hospitalOf(c.Department__c);
            if (h != null) {
                p.hospitalIds.add(h);
            }
        }
        if (c.Hospital__c != null) {
            p.hospitalIds.add(c.Hospital__c);
        }
        return p;
    }

    /** Profiles for Contacts, with hospitals and departments from active affiliations and the Account. */
    public static Map<Id, Profile> fromContacts(List<Contact> contacts) {
        HcoDirectory dir = HcoDirectory.get();
        Map<Id, Profile> out = new Map<Id, Profile>();
        for (Contact ct : contacts) {
            Profile p = new Profile();
            p.recordId = ct.Id;
            p.contact = ct;
            p.firstName = ct.FirstName;
            p.lastName = ct.LastName;
            p.email = ct.Email;
            p.registrationNumber = ct.Registration_Number__c;
            p.specialty = ct.Specialty__c;
            p.city = ct.MailingCity;
            p.organisation = ct.Account == null ? null : ct.Account.Name;
            addHco(p, ct.AccountId, dir);
            out.put(ct.Id, p);
        }
        if (!out.isEmpty()) {
            for (HCP_Affiliation__c a : [
                SELECT Contact__c, HCO__c
                FROM HCP_Affiliation__c
                WHERE Contact__c IN :out.keySet() AND Active__c = TRUE AND HCO__c != NULL
            ]) {
                addHco(out.get(a.Contact__c), a.HCO__c, dir);
            }
        }
        return out;
    }

    private static void addHco(Profile p, Id hcoId, HcoDirectory dir) {
        if (p == null || hcoId == null) {
            return;
        }
        Id h = dir.hospitalOf(hcoId);
        if (h == null) {
            return;
        }
        p.hospitalIds.add(h);
        if (dir.isDepartment(hcoId)) {
            p.departmentIds.add(hcoId);
        }
    }

    // ------------------------------------------------------------ normalisation

    private static final Map<String, String> ACCENTS = new Map<String, String>{
        'à' => 'a', 'á' => 'a', 'â' => 'a', 'ä' => 'a', 'ã' => 'a', 'å' => 'a',
        'è' => 'e', 'é' => 'e', 'ê' => 'e', 'ë' => 'e',
        'ì' => 'i', 'í' => 'i', 'î' => 'i', 'ï' => 'i',
        'ò' => 'o', 'ó' => 'o', 'ô' => 'o', 'ö' => 'o', 'õ' => 'o', 'ø' => 'o',
        'ù' => 'u', 'ú' => 'u', 'û' => 'u', 'ü' => 'u',
        'ç' => 'c', 'ñ' => 'n', 'ß' => 'ss'
    };

    /** Lower case, accents removed, only [a-z0-9@.] kept. */
    public static String normalize(String value) {
        if (value == null) {
            return '';
        }
        String v = value.toLowerCase();
        for (String k : ACCENTS.keySet()) {
            if (v.contains(k)) {
                v = v.replace(k, ACCENTS.get(k));
            }
        }
        return v.replaceAll('[^a-z0-9@.]', '');
    }

    /** Names: as normalize(), also without dots ("De Luca", "De' Luca" and "Deluca" are equal). */
    public static String normalizeName(String value) {
        return normalize(value).replace('.', '').replace('@', '');
    }

    /** Lower-case domain of an email address, or ''. */
    public static String emailDomain(String email) {
        if (String.isBlank(email) || !email.contains('@')) {
            return '';
        }
        return email.substringAfterLast('@').trim().toLowerCase();
    }

    /**
     * Registration number key: upper case, letters and digits only, leading zeros of the number removed
     * ("mi 020418", "MI-20418" and "MI/20418" all give MI20418).
     */
    public static String registrationKey(String value) {
        if (String.isBlank(value)) {
            return '';
        }
        String v = value.toUpperCase().replaceAll('[^A-Z0-9]', '');
        Matcher m = Pattern.compile('^([A-Z]*)0*([0-9]+)$').matcher(v);
        if (m.matches()) {
            return m.group(1) + m.group(2);
        }
        return v;
    }

    /** Digits of a registration key (province code removed). */
    public static String registrationDigits(String key) {
        return key == null ? '' : key.replaceAll('[^0-9]', '').replaceFirst('^0+', '');
    }

    private static Boolean isDigitsOnly(String key) {
        return String.isNotBlank(key) && key.isNumeric();
    }

    /** Sorts comparisons by score, highest first (stable, lists are small). */
    public static List<Comparison> sortByScore(List<Comparison> items) {
        for (Integer i = 1; i < items.size(); i++) {
            Comparison cur = items[i];
            Integer j = i - 1;
            while (j >= 0 && items[j].score < cur.score) {
                items[j + 1] = items[j];
                j--;
            }
            items[j + 1] = cur;
        }
        return items;
    }
}
