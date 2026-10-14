/**
 * Automatic matching of Capture__c records to existing HCPs (Contacts).
 *
 * Rules, in order (parameters in Custom Metadata Matching_Setting__mdt, record Default):
 *   0. Rep selected the HCP from search                    -> Auto-matched
 *   1. Identical email, exactly one HCP, no conflict       -> Auto-matched
 *   2. Identical registration number (normalised), one HCP -> Auto-matched
 *   3. Any candidate (name identical / swapped / similar,
 *      same surname, or an identifier shared by several
 *      HCPs or contradicted by another identifier)         -> To review, ranked candidates
 *   4. No candidate                                        -> New HCP (Contact created)
 *
 * Only identical identifiers auto-match. Hospital/department, email domain, fuzzy and swapped
 * names only find and rank candidates for a person to decide.
 *
 * Runs from the Capture_Matching_Request__e subscriber (Automated Process user),
 * so without sharing is required.
 */
public without sharing class CaptureMatchingService {
    public static final Integer MAX_CANDIDATES = 10;
    private static final String NO_MATCH = '#none#';

    /** Kept for the review UI and older callers: one scored candidate. */
    public class CandidateScore {
        public Contact contact;
        public String nameFlag;
        public String emailFlag;
        public String specialtyFlag;
        public String cityFlag;
        public String orgFlag;
        public String regFlag;
        public Integer score;
        public String explanation;
        public String nameKind;
        public String sharedHco;
    }

    /** Candidate pool for a set of captures, indexed for fast lookup. */
    private class Pool {
        public Map<Id, HcpMatchEngine.Profile> profiles = new Map<Id, HcpMatchEngine.Profile>();
        public Map<String, Set<Id>> byEmail = new Map<String, Set<Id>>();
        public Map<String, Set<Id>> byRegDigits = new Map<String, Set<Id>>();
        public Map<String, Set<Id>> byNamePrefix = new Map<String, Set<Id>>();
        public Map<Id, Set<Id>> byHospital = new Map<Id, Set<Id>>();
        /** Event Id -> HCPs registered for that event (imported registrations). */
        public Map<Id, Set<Id>> registeredByEvent = new Map<Id, Set<Id>>();
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
        MatchingConfig cfg = MatchingConfig.get();
        HcoDirectory dir = HcoDirectory.get();
        CaptureResolutionService.assignInternalOwners(captures);

        // Hospital from the organisation text or the email domain when the rep did not pick one.
        Map<Id, String> hospitalReason = new Map<Id, String>();
        for (Capture__c c : captures) {
            if (c.Hospital__c == null && c.Department__c != null) {
                c.Hospital__c = dir.hospitalOf(c.Department__c);
            }
            if (c.Hospital__c == null) {
                HcoDirectory.Resolution r = dir.resolve(c.Organisation__c, c.Email__c);
                if (r.hospitalId != null) {
                    c.Hospital__c = r.hospitalId;
                    hospitalReason.put(c.Id, r.reason);
                }
            }
        }

        Pool pool = loadPool(captures);

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
            HcpMatchEngine.Profile me = HcpMatchEngine.fromCapture(c);
            List<HcpMatchEngine.Comparison> comps = new List<HcpMatchEngine.Comparison>();
            Set<Id> registered = c.Channel__c == CaptureConstants.CHANNEL_REGISTRATION ? null : pool.registeredByEvent.get(c.Event__c);
            for (Id contactId : candidateIds(me, c, pool)) {
                HcpMatchEngine.Comparison cmp = HcpMatchEngine.compare(me, pool.profiles.get(contactId));
                if (registered != null && registered.contains(contactId) && cfg.wRegistered != 0) {
                    cmp.add(cfg.wRegistered, 'registered for this event');
                    cmp.score = Math.max(0, Math.min(100, cmp.score));
                }
                if (cmp.isCandidate()) {
                    comps.add(cmp);
                }
            }
            HcpMatchEngine.sortByScore(comps);

            List<HcpMatchEngine.Comparison> emailHits = new List<HcpMatchEngine.Comparison>();
            List<HcpMatchEngine.Comparison> regHits = new List<HcpMatchEngine.Comparison>();
            for (HcpMatchEngine.Comparison cmp : comps) {
                if (cmp.emailIdentical) {
                    emailHits.add(cmp);
                }
                if (cmp.regIdentical) {
                    regHits.add(cmp);
                }
            }

            String conflict = null;
            if (cfg.autoEmail && emailHits.size() == 1) {
                HcpMatchEngine.Comparison m = emailHits[0];
                Boolean regPointsElsewhere = !regHits.isEmpty() && !(regHits.size() == 1 && regHits[0].other.recordId == m.other.recordId);
                if (cfg.reviewOnConflict && m.regConflict) {
                    conflict = 'email matches but registration number differs';
                } else if (cfg.reviewOnConflict && regPointsElsewhere) {
                    conflict = 'email and registration number point to different HCPs';
                } else {
                    setAuto(c, m.other.recordId, 'Identical email');
                    resolved.add(c);
                    continue;
                }
            } else if (cfg.autoEmail && emailHits.size() > 1) {
                if (cfg.reviewOnConflict) {
                    conflict = 'email shared by ' + emailHits.size() + ' HCPs (possible duplicates)';
                } else {
                    setAuto(c, emailHits[0].other.recordId, 'Identical email');
                    resolved.add(c);
                    continue;
                }
            }
            if (conflict == null && cfg.autoRegistration && (emailHits.isEmpty() || !cfg.autoEmail)) {
                if (regHits.size() == 1) {
                    setAuto(c, regHits[0].other.recordId, 'Identical registration number');
                    resolved.add(c);
                    continue;
                } else if (regHits.size() > 1) {
                    if (cfg.reviewOnConflict) {
                        conflict = 'registration number shared by ' + regHits.size() + ' HCPs (possible duplicates)';
                    } else {
                        setAuto(c, regHits[0].other.recordId, 'Identical registration number');
                        resolved.add(c);
                        continue;
                    }
                }
            }

            if (!comps.isEmpty()) {
                List<CandidateScore> cands = new List<CandidateScore>();
                for (HcpMatchEngine.Comparison cmp : comps) {
                    if (cands.size() >= cfg.maxCandidates) {
                        break;
                    }
                    cands.add(toScore(cmp));
                }
                c.Matching_Status__c = CaptureConstants.MATCH_REVIEW;
                c.Processing_Stage__c = CaptureConstants.STAGE_TO_REVIEW;
                c.Match_Rule__c = (cands.size() + (cands.size() == 1 ? ' candidate' : ' candidates') + (conflict == null ? '' : ' - ' + conflict)).left(255);
                c.Candidate_Count__c = cands.size();
                c.Suggestion__c = buildSuggestion(c, cands, conflict, hospitalReason.get(c.Id));
                c.Suggestion_Confidence__c = confidence(cands, conflict, cfg);
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
                            Reg_Number_Match__c = s.regFlag,
                            Score_Explanation__c = s.explanation
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

    private static CandidateScore toScore(HcpMatchEngine.Comparison cmp) {
        CandidateScore s = new CandidateScore();
        s.contact = cmp.other.contact;
        s.nameFlag = cmp.nameFlag;
        s.emailFlag = cmp.emailFlag;
        s.specialtyFlag = cmp.specialtyFlag;
        s.cityFlag = cmp.cityFlag;
        s.orgFlag = cmp.orgFlag;
        s.regFlag = cmp.regFlag;
        s.score = cmp.score;
        s.explanation = cmp.explanationText();
        s.nameKind = cmp.nameKind;
        s.sharedHco = cmp.sharedHco;
        return s;
    }

    private static String confidence(List<CandidateScore> cands, String conflict, MatchingConfig cfg) {
        Integer top = cands[0].score;
        Integer gap = cands.size() > 1 ? top - cands[1].score : top;
        if (top >= cfg.highConfidenceScore && gap >= cfg.highConfidenceGap) {
            return 'High';
        }
        return top >= cfg.minCandidateScore * 2 || conflict != null ? 'Medium' : 'Low';
    }

    // ------------------------------------------------------------ candidate pool

    /** Contacts sharing an email, a registration number, a 3-letter name prefix (also swapped) or the capture's hospital. */
    private static Pool loadPool(List<Capture__c> captures) {
        Set<String> emails = new Set<String>{ NO_MATCH };
        List<String> regLikes = new List<String>{ NO_MATCH };
        List<String> prefixes = new List<String>{ NO_MATCH };
        Set<Id> hospitalIds = new Set<Id>();
        for (Capture__c c : captures) {
            if (String.isNotBlank(c.Email__c)) {
                emails.add(c.Email__c.trim().toLowerCase());
            }
            String digits = HcpMatchEngine.registrationDigits(HcpMatchEngine.registrationKey(c.Registration_Number__c));
            if (digits.length() >= 4) {
                regLikes.add('%' + digits);
            }
            for (String n : new List<String>{ c.Last_Name__c, c.First_Name__c }) {
                String p = likePrefix(n);
                if (p != null) {
                    prefixes.add(p);
                }
            }
            if (c.Hospital__c != null) {
                hospitalIds.add(c.Hospital__c);
            }
        }
        Map<Id, Contact> contacts = new Map<Id, Contact>(
            [
                SELECT Id, FirstName, LastName, Email, Specialty__c, MailingCity, Registration_Number__c, Registration_Key__c, OneKey_Id__c, AccountId, Account.Name
                FROM Contact
                WHERE Email IN :emails OR Registration_Key__c LIKE :regLikes OR LastName LIKE :prefixes OR FirstName LIKE :prefixes
                ORDER BY CreatedDate ASC
                LIMIT 5000
            ]
        );
        if (!hospitalIds.isEmpty()) {
            Set<Id> extra = new Set<Id>();
            for (HCP_Affiliation__c a : [
                SELECT Contact__c
                FROM HCP_Affiliation__c
                WHERE (HCO__c IN :hospitalIds OR HCO__r.ParentId IN :hospitalIds) AND Active__c = TRUE
                LIMIT 5000
            ]) {
                if (!contacts.containsKey(a.Contact__c)) {
                    extra.add(a.Contact__c);
                }
            }
            if (!extra.isEmpty()) {
                contacts.putAll(
                    [
                        SELECT Id, FirstName, LastName, Email, Specialty__c, MailingCity, Registration_Number__c, Registration_Key__c, OneKey_Id__c, AccountId, Account.Name
                        FROM Contact
                        WHERE Id IN :extra
                    ]
                );
            }
        }

        Pool pool = new Pool();
        Set<Id> eventIds = new Set<Id>();
        for (Capture__c c : captures) {
            if (c.Event__c != null) {
                eventIds.add(c.Event__c);
            }
        }
        if (!eventIds.isEmpty() && !contacts.isEmpty()) {
            Set<Id> contactIds = contacts.keySet();
            for (Event_Attendee__c a : [
                SELECT Event__c, Contact__c
                FROM Event_Attendee__c
                WHERE Event__c IN :eventIds AND Contact__c IN :contactIds AND Registered__c = TRUE
            ]) {
                if (!pool.registeredByEvent.containsKey(a.Event__c)) {
                    pool.registeredByEvent.put(a.Event__c, new Set<Id>());
                }
                pool.registeredByEvent.get(a.Event__c).add(a.Contact__c);
            }
        }
        pool.profiles = HcpMatchEngine.fromContacts(contacts.values());
        for (HcpMatchEngine.Profile p : pool.profiles.values()) {
            p.prepare();
            index(pool.byEmail, p.nEmail, p.recordId);
            index(pool.byRegDigits, HcpMatchEngine.registrationDigits(p.regKey), p.recordId);
            index(pool.byNamePrefix, p.nLast.left(3), p.recordId);
            index(pool.byNamePrefix, p.nFirst.left(3), p.recordId);
            for (Id h : p.hospitalIds) {
                if (!pool.byHospital.containsKey(h)) {
                    pool.byHospital.put(h, new Set<Id>());
                }
                pool.byHospital.get(h).add(p.recordId);
            }
        }
        return pool;
    }

    private static Set<Id> candidateIds(HcpMatchEngine.Profile me, Capture__c c, Pool pool) {
        me.prepare();
        Set<Id> ids = new Set<Id>();
        addAll(ids, pool.byEmail.get(me.nEmail));
        addAll(ids, pool.byRegDigits.get(HcpMatchEngine.registrationDigits(me.regKey)));
        addAll(ids, pool.byNamePrefix.get(me.nLast.left(3)));
        addAll(ids, pool.byNamePrefix.get(me.nFirst.left(3)));
        for (Id h : me.hospitalIds) {
            addAll(ids, pool.byHospital.get(h));
        }
        ids.remove(null);
        return ids;
    }

    private static void index(Map<String, Set<Id>> m, String key, Id value) {
        if (String.isBlank(key)) {
            return;
        }
        if (!m.containsKey(key)) {
            m.put(key, new Set<Id>());
        }
        m.get(key).add(value);
    }

    private static void addAll(Set<Id> target, Set<Id> source) {
        if (source != null) {
            target.addAll(source);
        }
    }

    /** SOQL LIKE pattern on the first 3 characters of a name, or null. */
    private static String likePrefix(String name) {
        if (String.isBlank(name)) {
            return null;
        }
        String n = name.trim().replaceAll('[%_\\\\]', '');
        return n.length() < 2 ? null : n.left(3) + '%';
    }

    // ------------------------------------------------------------ scoring (kept for callers and tests)

    /** Ranks existing Contacts for a capture with the matching engine (no DML). */
    public static List<CandidateScore> rankCandidates(Capture__c c, List<Contact> contacts) {
        HcpMatchEngine.Profile me = HcpMatchEngine.fromCapture(c);
        List<HcpMatchEngine.Comparison> comps = new List<HcpMatchEngine.Comparison>();
        for (HcpMatchEngine.Profile p : HcpMatchEngine.fromContacts(contacts).values()) {
            HcpMatchEngine.Comparison cmp = HcpMatchEngine.compare(me, p);
            if (cmp.isCandidate()) {
                comps.add(cmp);
            }
        }
        HcpMatchEngine.sortByScore(comps);
        List<CandidateScore> out = new List<CandidateScore>();
        for (HcpMatchEngine.Comparison cmp : comps) {
            if (out.size() >= MatchingConfig.get().maxCandidates) {
                break;
            }
            out.add(toScore(cmp));
        }
        return out;
    }

    /** Lower case, accents removed, only [a-z0-9@.] kept (same as the mockup). */
    public static String normalize(String value) {
        return HcpMatchEngine.normalize(value);
    }

    // ------------------------------------------------------------ suggestion (deterministic)

    public static String buildSuggestion(Capture__c c, List<CandidateScore> cands, String conflict, String hospitalReason) {
        CandidateScore top = cands[0];
        List<String> reasons = new List<String>();
        if (top.nameKind == HcpMatchEngine.NAME_EXACT) {
            reasons.add('same full name');
        } else if (top.nameKind == HcpMatchEngine.NAME_SWAPPED) {
            reasons.add('same name with first and last name swapped');
        } else if (top.nameKind == HcpMatchEngine.NAME_FUZZY) {
            reasons.add('similar name');
        } else if (top.nameKind == HcpMatchEngine.NAME_SURNAME) {
            reasons.add('same surname');
        }
        if (top.emailFlag == CaptureConstants.FLAG_EXACT) {
            reasons.add('email');
        }
        if (top.regFlag == CaptureConstants.FLAG_EXACT) {
            reasons.add('registration number');
        }
        if (top.orgFlag == CaptureConstants.FLAG_EXACT) {
            reasons.add('department');
        } else if (top.orgFlag == CaptureConstants.FLAG_PARTIAL && top.sharedHco != null) {
            reasons.add('hospital');
        }
        if (top.cityFlag == CaptureConstants.FLAG_EXACT) {
            reasons.add('city');
        }
        if (top.specialtyFlag == CaptureConstants.FLAG_EXACT) {
            reasons.add('specialty');
        }
        if (reasons.isEmpty()) {
            reasons.add('best overall score');
        }
        String reasonText = reasons.size() == 1
            ? reasons[0]
            : String.join(sublist(reasons, 0, reasons.size() - 1), ', ') + ' and ' + reasons[reasons.size() - 1];

        List<String> details = new List<String>();
        if (conflict != null) {
            details.add('Attention: ' + conflict);
        }
        details.add(top.nameFlag == CaptureConstants.FLAG_EXACT ? 'First name matches' : 'First name differs or is spelled differently');
        if (String.isBlank(c.Email__c)) {
            details.add('no email');
        } else if (top.emailFlag == CaptureConstants.FLAG_EXACT) {
            details.add('email matches');
        } else {
            Boolean personal = MatchingConfig.get().isPersonalDomain(HcpMatchEngine.emailDomain(c.Email__c));
            details.add('email differs (' + (personal ? 'personal address' : 'different address') + ')');
        }
        if (String.isBlank(c.Registration_Number__c)) {
            details.add('no registration number captured');
        } else {
            details.add(
                top.regFlag == CaptureConstants.FLAG_EXACT
                    ? 'registration number matches'
                    : (top.regFlag == CaptureConstants.FLAG_PARTIAL ? 'registration number matches without province' : 'registration number differs')
            );
        }
        if (hospitalReason != null) {
            details.add('hospital inferred from ' + hospitalReason);
        }

        String text = 'Recommended: Dr. ' + (top.contact.FirstName == null ? '' : top.contact.FirstName + ' ') + top.contact.LastName +
            ' - ' + reasonText + ' (score ' + top.score + ')\n' + String.join(details, ' · ') + '.';
        for (Integer i = 1; i < cands.size(); i++) {
            CandidateScore x = cands[i];
            List<String> diffs = new List<String>();
            if (x.orgFlag != CaptureConstants.FLAG_EXACT && x.orgFlag != CaptureConstants.FLAG_PARTIAL) {
                diffs.add('different hospital');
            }
            if (x.cityFlag != CaptureConstants.FLAG_EXACT) {
                diffs.add('different city');
            }
            if (x.specialtyFlag != CaptureConstants.FLAG_EXACT) {
                diffs.add('different specialty');
            }
            if (x.nameFlag != CaptureConstants.FLAG_EXACT) {
                diffs.add('different first name');
            }
            text += '\n- ' + (x.contact.FirstName == null ? '' : x.contact.FirstName + ' ') + x.contact.LastName + ' (' +
                (x.contact.MailingCity == null ? '?' : x.contact.MailingCity) + ', ' + (x.contact.Specialty__c == null ? '?' : x.contact.Specialty__c) +
                ', score ' + x.score + ') - ' + (diffs.isEmpty() ? 'weaker overall match' : String.join(diffs, ', '));
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
