/**
 * Automatic matching of Capture__c records to existing HCPs (Contacts).
 *
 * Rules, in order:
 *   0. Rep selected the HCP from search          -> Auto-matched
 *   1. Identical email                           -> Auto-matched
 *   2. Identical registration number (normalised)-> Auto-matched
 *   3. Same surname (namesakes)                  -> To review, ranked candidates
 *   4. No candidate                              -> New HCP (Contact created)
 *
 * Runs from the Capture_Matching_Request__e subscriber (Automated Process user),
 * so without sharing is required.
 */
public without sharing class CaptureMatchingService {
    public static final Integer MAX_CANDIDATES = 10;

    public class CandidateScore {
        public Contact contact;
        public String nameFlag;
        public String emailFlag;
        public String specialtyFlag;
        public String cityFlag;
        public String orgFlag;
        public String regFlag;
        public Integer score;
    }

    // ------------------------------------------------------------ entry point

    public static void processCaptures(Set<Id> captureIds) {
        captureIds.remove(null);
        if (captureIds.isEmpty()) {
            return;
        }
        List<Capture__c> captures = CaptureResolutionService.loadCaptures(captureIds);
        List<Capture__c> queued = new List<Capture__c>();
        for (Capture__c c : captures) {
            if (c.Matching_Status__c == CaptureConstants.MATCH_QUEUED) {
                queued.add(c);
            }
        }
        if (queued.isEmpty()) {
            return;
        }
        try {
            match(queued);
        } catch (Exception e) {
            markError(queued, e);
        }
    }

    private static void markError(List<Capture__c> captures, Exception e) {
        List<Capture__c> updates = new List<Capture__c>();
        for (Capture__c c : captures) {
            updates.add(
                new Capture__c(
                    Id = c.Id,
                    Processing_Stage__c = CaptureConstants.STAGE_ERROR,
                    Matching_Status__c = CaptureConstants.MATCH_ERROR,
                    Processing_Error__c = (e.getTypeName() + ': ' + e.getMessage() + '\n' + e.getStackTraceString()).left(5000)
                )
            );
        }
        Database.update(updates, false);
    }

    // ------------------------------------------------------------ matching

    @TestVisible
    private static void match(List<Capture__c> captures) {
        CaptureResolutionService.assignInternalOwners(captures);

        Set<String> emails = new Set<String>();
        Set<String> regKeys = new Set<String>();
        Set<String> lastNames = new Set<String>();
        for (Capture__c c : captures) {
            if (String.isNotBlank(c.Email__c)) {
                emails.add(c.Email__c.trim().toLowerCase());
            }
            if (String.isNotBlank(c.Registration_Key__c)) {
                regKeys.add(c.Registration_Key__c);
            }
            if (String.isNotBlank(c.Last_Name__c)) {
                lastNames.add(c.Last_Name__c.trim());
            }
        }
        Map<Id, Contact> pool = new Map<Id, Contact>();
        if (!emails.isEmpty() || !regKeys.isEmpty() || !lastNames.isEmpty()) {
            for (Contact ct : [
                SELECT
                    Id,
                    FirstName,
                    LastName,
                    Email,
                    Specialty__c,
                    MailingCity,
                    Registration_Number__c,
                    Registration_Key__c,
                    OneKey_Id__c,
                    Account.Name
                FROM Contact
                WHERE Email IN :emails OR Registration_Key__c IN :regKeys OR LastName IN :lastNames
                ORDER BY CreatedDate ASC
                LIMIT 2000
            ]) {
                pool.put(ct.Id, ct);
            }
        }

        List<Capture__c> resolved = new List<Capture__c>();
        List<Capture__c> needNewContact = new List<Capture__c>();
        List<Capture__c> toReview = new List<Capture__c>();
        Map<Id, List<CandidateScore>> candidatesByCapture = new Map<Id, List<CandidateScore>>();

        for (Capture__c c : captures) {
            if (c.HCP_Selected_By_Rep__c && c.Matched_Contact__c != null) {
                setAuto(c, c.Matched_Contact__c, 'HCP selected by rep');
                resolved.add(c);
                continue;
            }
            Contact byEmail = findByEmail(c, pool.values());
            if (byEmail != null) {
                setAuto(c, byEmail.Id, 'Identical email');
                resolved.add(c);
                continue;
            }
            Contact byReg = findByReg(c, pool.values());
            if (byReg != null) {
                setAuto(c, byReg.Id, 'Identical registration number');
                resolved.add(c);
                continue;
            }
            List<CandidateScore> cands = rankCandidates(c, pool.values());
            if (!cands.isEmpty()) {
                c.Matching_Status__c = CaptureConstants.MATCH_REVIEW;
                c.Processing_Stage__c = CaptureConstants.STAGE_TO_REVIEW;
                c.Match_Rule__c = cands.size() + (cands.size() == 1 ? ' namesake candidate' : ' namesake candidates');
                c.Candidate_Count__c = cands.size();
                c.Suggestion__c = buildSuggestion(c, cands);
                c.Suggestion_Confidence__c = cands[0].score >= 55 ? 'High' : 'Medium';
                candidatesByCapture.put(c.Id, cands);
                toReview.add(c);
                continue;
            }
            c.Matching_Status__c = CaptureConstants.MATCH_NEW;
            c.Match_Rule__c = 'No candidate found';
            c.Matched_By__c = 'Matching engine (No candidate found - new HCP created)';
            needNewContact.add(c);
        }

        if (!needNewContact.isEmpty()) {
            CaptureResolutionService.createContactsFor(needNewContact);
            resolved.addAll(needNewContact);
        }

        if (!toReview.isEmpty()) {
            // re-runs replace the previous candidate list
            delete [SELECT Id FROM Capture_Candidate__c WHERE Capture__c IN :toReview];
            List<Capture_Candidate__c> rows = new List<Capture_Candidate__c>();
            for (Capture__c c : toReview) {
                Integer rank = 1;
                for (CandidateScore s : candidatesByCapture.get(c.Id)) {
                    rows.add(
                        new Capture_Candidate__c(
                            Capture__c = c.Id,
                            Contact__c = s.contact.Id,
                            Score__c = s.score,
                            Rank__c = rank,
                            Recommended__c = rank == 1,
                            Name_Match__c = s.nameFlag,
                            Email_Match__c = s.emailFlag,
                            Specialty_Match__c = s.specialtyFlag,
                            City_Match__c = s.cityFlag,
                            Organisation_Match__c = s.orgFlag,
                            Reg_Number_Match__c = s.regFlag
                        )
                    );
                    rank++;
                }
            }
            insert rows;
            update toReview;
        }

        if (!resolved.isEmpty()) {
            CaptureResolutionService.complete(resolved);
        }
    }

    private static void setAuto(Capture__c c, Id contactId, String rule) {
        c.Matched_Contact__c = contactId;
        c.Matching_Status__c = CaptureConstants.MATCH_AUTO;
        c.Match_Rule__c = rule;
        c.Matched_By__c = 'Matching engine (' + rule + ')';
    }

    private static Contact findByEmail(Capture__c c, List<Contact> pool) {
        if (String.isBlank(c.Email__c)) {
            return null;
        }
        String e = c.Email__c.trim();
        for (Contact ct : pool) {
            if (ct.Email != null && ct.Email.equalsIgnoreCase(e)) {
                return ct;
            }
        }
        return null;
    }

    private static Contact findByReg(Capture__c c, List<Contact> pool) {
        if (String.isBlank(c.Registration_Key__c)) {
            return null;
        }
        for (Contact ct : pool) {
            if (ct.Registration_Key__c != null && ct.Registration_Key__c == c.Registration_Key__c) {
                return ct;
            }
        }
        return null;
    }

    // ------------------------------------------------------------ scoring

    public static List<CandidateScore> rankCandidates(Capture__c c, List<Contact> pool) {
        List<CandidateScore> result = new List<CandidateScore>();
        String last = normalize(c.Last_Name__c);
        if (String.isBlank(last)) {
            return result;
        }
        for (Contact ct : pool) {
            if (normalize(ct.LastName) == last) {
                result.add(score(c, ct));
            }
        }
        // simple insertion sort, highest score first (lists are small)
        for (Integer i = 1; i < result.size(); i++) {
            CandidateScore cur = result[i];
            Integer j = i - 1;
            while (j >= 0 && result[j].score < cur.score) {
                result[j + 1] = result[j];
                j--;
            }
            result[j + 1] = cur;
        }
        while (result.size() > MAX_CANDIDATES) {
            result.remove(result.size() - 1);
        }
        return result;
    }

    public static CandidateScore score(Capture__c c, Contact ct) {
        CandidateScore s = new CandidateScore();
        s.contact = ct;
        Boolean sameLast = normalize(c.Last_Name__c) == normalize(ct.LastName);
        Boolean sameFirst = normalize(c.First_Name__c) == normalize(ct.FirstName);
        s.nameFlag = sameLast && sameFirst ? CaptureConstants.FLAG_EXACT : (sameLast ? CaptureConstants.FLAG_PARTIAL : CaptureConstants.FLAG_NONE);
        s.emailFlag = flag(c.Email__c, ct.Email);
        s.specialtyFlag = flag(c.Specialty__c, ct.Specialty__c);
        s.cityFlag = flag(c.City__c, ct.MailingCity);
        s.regFlag = String.isBlank(c.Registration_Key__c)
            ? CaptureConstants.FLAG_NA
            : (c.Registration_Key__c == ct.Registration_Key__c ? CaptureConstants.FLAG_EXACT : CaptureConstants.FLAG_NONE);
        String orgC = normalize(c.Organisation__c);
        String orgH = normalize(ct.Account == null ? null : ct.Account.Name);
        if (String.isBlank(orgC)) {
            s.orgFlag = CaptureConstants.FLAG_NA;
        } else if (String.isNotBlank(orgH) && (orgH.contains(orgC) || orgC.contains(orgH))) {
            s.orgFlag = CaptureConstants.FLAG_PARTIAL;
        } else {
            s.orgFlag = CaptureConstants.FLAG_NONE;
        }
        s.score =
            (s.nameFlag == CaptureConstants.FLAG_EXACT ? 30 : (s.nameFlag == CaptureConstants.FLAG_PARTIAL ? 15 : 0)) +
            (s.emailFlag == CaptureConstants.FLAG_EXACT ? 25 : 0) +
            (s.cityFlag == CaptureConstants.FLAG_EXACT ? 15 : 0) +
            (s.specialtyFlag == CaptureConstants.FLAG_EXACT ? 15 : 0) +
            (s.regFlag == CaptureConstants.FLAG_EXACT ? 15 : 0);
        return s;
    }

    private static String flag(String captured, String existing) {
        if (String.isBlank(captured)) {
            return CaptureConstants.FLAG_NA;
        }
        return normalize(captured) == normalize(existing) ? CaptureConstants.FLAG_EXACT : CaptureConstants.FLAG_NONE;
    }

    private static final Map<String, String> ACCENTS = new Map<String, String>{
        'à' => 'a', 'á' => 'a', 'â' => 'a', 'ä' => 'a', 'ã' => 'a',
        'è' => 'e', 'é' => 'e', 'ê' => 'e', 'ë' => 'e',
        'ì' => 'i', 'í' => 'i', 'î' => 'i', 'ï' => 'i',
        'ò' => 'o', 'ó' => 'o', 'ô' => 'o', 'ö' => 'o', 'õ' => 'o',
        'ù' => 'u', 'ú' => 'u', 'û' => 'u', 'ü' => 'u',
        'ç' => 'c', 'ñ' => 'n'
    };

    /** Lower case, accents removed, only [a-z0-9@.] kept (same as the mockup). */
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

    // ------------------------------------------------------------ suggestion (phase 1: deterministic)

    public static String buildSuggestion(Capture__c c, List<CandidateScore> cands) {
        CandidateScore top = cands[0];
        List<String> reasons = new List<String>{ 'same surname' };
        if (top.cityFlag == CaptureConstants.FLAG_EXACT) {
            reasons.add('city');
        }
        if (top.specialtyFlag == CaptureConstants.FLAG_EXACT) {
            reasons.add('specialty');
        }
        String reasonText = reasons.size() == 1
            ? reasons[0]
            : String.join(sublist(reasons, 0, reasons.size() - 1), ', ') + ' and ' + reasons[reasons.size() - 1];

        List<String> details = new List<String>();
        details.add(top.nameFlag == CaptureConstants.FLAG_EXACT ? 'First name matches' : 'First name differs');
        if (String.isBlank(c.Email__c)) {
            details.add('no email');
        } else if (top.emailFlag == CaptureConstants.FLAG_EXACT) {
            details.add('email matches');
        } else {
            String domain = c.Email__c.substringAfter('@').toLowerCase();
            Boolean personal = domain.startsWith('gmail') || domain.startsWith('yahoo') || domain.startsWith('hotmail') ||
                domain.startsWith('libero') || domain.startsWith('outlook') || domain.startsWith('icloud');
            details.add('email differs (' + (personal ? 'personal vs. institutional domain' : 'different address') + ')');
        }
        if (String.isBlank(c.Registration_Key__c)) {
            details.add('no registration number captured');
        } else {
            details.add(top.regFlag == CaptureConstants.FLAG_EXACT ? 'registration number matches' : 'registration number differs');
        }

        String text = 'Recommended: Dr. ' + top.contact.FirstName + ' ' + top.contact.LastName + ' - ' + reasonText + '\n' +
            String.join(details, ' · ') + '.';
        for (Integer i = 1; i < cands.size(); i++) {
            CandidateScore x = cands[i];
            List<String> diffs = new List<String>();
            if (x.cityFlag != CaptureConstants.FLAG_EXACT) {
                diffs.add('different city');
            }
            if (x.specialtyFlag != CaptureConstants.FLAG_EXACT) {
                diffs.add('different specialty');
            }
            if (x.nameFlag != CaptureConstants.FLAG_EXACT) {
                diffs.add('different first name');
            }
            text += '\n- ' + x.contact.FirstName + ' ' + x.contact.LastName + ' (' + (x.contact.MailingCity == null ? '?' : x.contact.MailingCity) +
                ', ' + (x.contact.Specialty__c == null ? '?' : x.contact.Specialty__c) + ') - ' +
                (diffs.isEmpty() ? 'weaker overall match' : String.join(diffs, ', '));
        }
        return text.left(5000);
    }

    private static List<String> sublist(List<String> values, Integer fromIdx, Integer toIdx) {
        List<String> out = new List<String>();
        for (Integer i = fromIdx; i < toIdx; i++) {
            out.add(values[i]);
        }
        return out;
    }
}
