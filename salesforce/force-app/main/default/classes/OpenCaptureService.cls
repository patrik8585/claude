/**
 * Kiosk and QR entries of a congress that are still waiting to be identified, for the rep page.
 *
 * Why: when an HCP uses the kiosk first and then comes to the rep, the kiosk entry has no HCP yet,
 * so the normal Salesforce search on the rep page cannot find it. The rep would create the HCP
 * again (walk-in) and the BA would later create a second one from the kiosk entry. The rep page
 * therefore also lists the open kiosk / QR entries of the same congress: the rep identifies the HCP
 * and the entry is closed, so it never reaches the review queue.
 *
 * without sharing: kiosk / QR captures belong to the congress owner (the guest user never owns them),
 * so a rep cannot read them with sharing. This class reads and resolves ONLY entries that are
 * - of the given, active congress,
 * - from the Kiosk or QR self-scan channel,
 * - still open (Matching Status Queued or To review).
 * Callers check the rep permission first (RepCaptureController).
 */
public without sharing class OpenCaptureService {
    public static final Set<String> SELF_CHANNELS = new Set<String>{ CaptureConstants.CHANNEL_SELF, CaptureConstants.CHANNEL_KIOSK };
    public static final Set<String> OPEN_STATUSES = new Set<String>{ CaptureConstants.MATCH_QUEUED, CaptureConstants.MATCH_REVIEW };
    public static final String RULE_LINKED = 'Identified by rep at the stand';
    public static final String RULE_NEW = 'Identified by rep at the stand - new HCP';
    private static final Integer MAX_RESULTS = 20;
    private static final Integer MAX_TOKENS = 4;

    /** Open entries of the congress whose name, email or registration number contains every word of the term. */
    public static List<RepCaptureController.OpenEntry> search(String term, String eventId) {
        List<RepCaptureController.OpenEntry> out = new List<RepCaptureController.OpenEntry>();
        List<String> words = tokens(term);
        Id evId = toId(eventId);
        if (words.isEmpty() || evId == null) {
            return out;
        }
        List<String> patterns = new List<String>();
        for (String w : words) {
            patterns.add('%' + w + '%');
        }
        for (Capture__c c : [
            SELECT
                Id,
                First_Name__c,
                Last_Name__c,
                Email__c,
                Specialty__c,
                City__c,
                Organisation__c,
                Registration_Number__c,
                Channel__c,
                Captured_At__c,
                Consent_Given__c,
                Opt_In_Status__c
            FROM Capture__c
            WHERE
                Event__c = :evId
                AND Event__r.Active__c = TRUE
                AND Channel__c IN :SELF_CHANNELS
                AND Matching_Status__c IN :OPEN_STATUSES
                AND (Last_Name__c LIKE :patterns
                OR First_Name__c LIKE :patterns
                OR Email__c LIKE :patterns
                OR Registration_Number__c LIKE :patterns)
            ORDER BY Captured_At__c DESC
            LIMIT 200
        ]) {
            if (containsAll(c, words)) {
                out.add(toEntry(c));
                if (out.size() >= MAX_RESULTS) {
                    break;
                }
            }
        }
        return out;
    }

    /** The rep says the entry is this HCP: the entry is completed (consent, attendee) like a steward match. */
    public static String link(String captureId, Id contactId) {
        Capture__c c = lockOpen(captureId);
        c.Matched_Contact__c = contactId;
        c.Matching_Status__c = CaptureConstants.MATCH_REVIEWED;
        c.Match_Rule__c = RULE_LINKED;
        c.Matched_By__c = ('Rep - ' + UserInfo.getName() + ' (identified at the stand)').left(255);
        stampReview(c);
        CaptureResolutionService.complete(new List<Capture__c>{ c });
        return 'Kiosk / QR entry linked to the HCP: attendance and the consent given at the kiosk are recorded.';
    }

    /** The HCP is not in Salesforce: the HCP is created from the entry the HCP typed, then completed. */
    public static String createHcp(String captureId) {
        Capture__c c = lockOpen(captureId);
        c.Matching_Status__c = CaptureConstants.MATCH_REVIEWED_NEW;
        c.Match_Rule__c = RULE_NEW;
        c.Matched_By__c = ('Rep - ' + UserInfo.getName() + ' (new HCP created at the stand)').left(255);
        stampReview(c);
        List<Capture__c> caps = new List<Capture__c>{ c };
        CaptureResolutionService.createContactsFor(caps);
        CaptureResolutionService.complete(caps);
        return 'New HCP created from the kiosk / QR entry: attendance and the consent given at the kiosk are recorded.';
    }

    // ------------------------------------------------------------ helpers

    /** Locks the entry and checks it is still an open kiosk / QR entry of an active congress. */
    private static Capture__c lockOpen(String captureId) {
        Id capId = toId(captureId);
        if (capId == null || capId.getSobjectType() != Capture__c.SObjectType) {
            throw new AuraHandledException('Kiosk or QR entry not found.');
        }
        // FOR UPDATE: the asynchronous matching or a BA may be working on the same entry
        List<Capture__c> locked = [
            SELECT Id, Event__c, Channel__c, Matching_Status__c
            FROM Capture__c
            WHERE Id = :capId
            FOR UPDATE
        ];
        if (locked.isEmpty() || !SELF_CHANNELS.contains(locked[0].Channel__c)) {
            throw new AuraHandledException('Kiosk or QR entry not found.');
        }
        if (!OPEN_STATUSES.contains(locked[0].Matching_Status__c)) {
            throw new AuraHandledException(
                'This entry has just been identified (status: ' + locked[0].Matching_Status__c + '). Search again.'
            );
        }
        if ([SELECT COUNT() FROM Event__c WHERE Id = :locked[0].Event__c AND Active__c = TRUE] == 0) {
            throw new AuraHandledException('The congress of this entry is not active.');
        }
        return CaptureResolutionService.loadCaptures(new Set<Id>{ capId })[0];
    }

    private static void stampReview(Capture__c c) {
        update new Capture__c(Id = c.Id, Reviewed_By__c = UserInfo.getUserId(), Reviewed_At__c = System.now());
    }

    @TestVisible
    private static List<String> tokens(String term) {
        List<String> out = new List<String>();
        if (String.isBlank(term)) {
            return out;
        }
        for (String w : term.trim().toLowerCase().split('\\s+')) {
            if (w.length() >= 2 && !out.contains(w)) {
                out.add(w);
            }
            if (out.size() >= MAX_TOKENS) {
                break;
            }
        }
        return out;
    }

    private static Boolean containsAll(Capture__c c, List<String> words) {
        String hay = String.join(
                new List<String>{ blankIfNull(c.First_Name__c), blankIfNull(c.Last_Name__c), blankIfNull(c.Email__c), blankIfNull(c.Registration_Number__c) },
                ' '
            )
            .toLowerCase();
        for (String w : words) {
            if (!hay.contains(w)) {
                return false;
            }
        }
        return true;
    }

    private static String blankIfNull(String value) {
        return value == null ? '' : value;
    }

    private static Id toId(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        try {
            return Id.valueOf(value);
        } catch (Exception e) {
            return null;
        }
    }

    private static RepCaptureController.OpenEntry toEntry(Capture__c c) {
        RepCaptureController.OpenEntry e = new RepCaptureController.OpenEntry();
        e.id = c.Id;
        e.firstName = c.First_Name__c;
        e.lastName = c.Last_Name__c;
        e.email = c.Email__c;
        e.specialty = c.Specialty__c;
        e.city = c.City__c;
        e.organisation = c.Organisation__c;
        e.registrationNumber = c.Registration_Number__c;
        e.channelLabel = c.Channel__c == CaptureConstants.CHANNEL_KIOSK ? 'Kiosk' : 'QR';
        e.timeLabel = c.Captured_At__c == null ? '' : c.Captured_At__c.format('dd/MM HH:mm');
        if (c.Consent_Given__c != true || c.Opt_In_Status__c == CaptureConstants.OPTIN_DECLINED) {
            e.consentLabel = 'Declined at the kiosk';
        } else if (c.Opt_In_Status__c == CaptureConstants.OPTIN_CONFIRMED) {
            e.consentLabel = 'Given at the kiosk';
        } else {
            e.consentLabel = 'Given at the kiosk, email confirmation pending';
        }
        return e;
    }
}
