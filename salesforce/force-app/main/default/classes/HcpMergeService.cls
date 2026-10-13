/**
 * Merges two HCP Contacts (Database.merge) chosen by a data steward and keeps an immutable audit
 * record (HCP_Merge__c): who, when, both records' values and the field choices.
 *
 * Related records are preserved: Salesforce moves consents, captures, candidates, attendees and
 * affiliations of the merged HCP to the surviving one. Before the merge, records that would clash
 * with a unique key (same department, same event, same duplicate pair) are folded into the survivor.
 *
 * Consent evidence: Consent__c.Evidence_Hash__c was computed with the Contact Id at capture time and is
 * never rewritten. "Verify evidence" retries the hash with the Contact Ids recorded in HCP_Merge__c
 * (see verificationContactIds).
 */
public without sharing class HcpMergeService {
    /** Fields the steward can pick from either record, in display order. */
    public static final List<String> MERGE_FIELDS = new List<String>{
        'FirstName',
        'LastName',
        'Email',
        'Phone',
        'MobilePhone',
        'Title',
        'Specialty__c',
        'Registration_Number__c',
        'OneKey_Id__c',
        'MailingCity',
        'Territory__c',
        'AccountId'
    };

    public class MergeException extends Exception {
    }

    private static String fieldList() {
        return 'Id, Name, CreatedDate, Consent_Status__c, Test_Duplicate_Of__c, Test_Data_Set__c, ' + String.join(MERGE_FIELDS, ', ');
    }

    public static Contact load(Id contactId) {
        List<Contact> rows = Database.query('SELECT ' + fieldList() + ' FROM Contact WHERE Id = :contactId');
        if (rows.isEmpty()) {
            throw new MergeException('HCP not found (already merged or deleted?).');
        }
        return rows[0];
    }

    /**
     * Merges duplicateId into masterId.
     * choices: field API name -> 'master' | 'duplicate' (missing = keep the master value, or take the
     * duplicate's when the master is blank).
     */
    public static HCP_Merge__c mergeHcps(Id masterId, Id duplicateId, Map<String, String> choices, Id pairId) {
        if (masterId == null || duplicateId == null || masterId == duplicateId) {
            throw new MergeException('Choose two different HCPs.');
        }
        if (choices == null) {
            choices = new Map<String, String>();
        }
        Contact master = load(masterId);
        Contact dup = load(duplicateId);
        String masterBefore = JSON.serialize(master);
        String dupSnapshot = JSON.serialize(dup);

        // ---- field values for the survivor
        Contact upd = new Contact(Id = masterId);
        Map<String, Object> choiceLog = new Map<String, Object>();
        for (String f : MERGE_FIELDS) {
            String choice = choices.get(f);
            Object mv = master.get(f);
            Object dv = dup.get(f);
            if (choice == null) {
                choice = (mv == null && dv != null) ? 'duplicate' : 'master';
            }
            Object chosen = choice == 'duplicate' ? dv : mv;
            if (choice == 'duplicate' && dv != mv) {
                upd.put(f, dv);
            }
            choiceLog.put(f, new Map<String, Object>{ 'choice' => choice, 'master' => mv, 'duplicate' => dv, 'kept' => chosen });
        }
        // the survivor must not end up flagged as a duplicate of the record it absorbs
        if (master.Test_Duplicate_Of__c == duplicateId) {
            upd.Test_Duplicate_Of__c = dup.Test_Duplicate_Of__c == masterId ? null : dup.Test_Duplicate_Of__c;
        }

        // ---- counts for the audit, before anything moves
        Integer consents = [SELECT COUNT() FROM Consent__c WHERE Contact__c = :duplicateId];
        Integer captures = [SELECT COUNT() FROM Capture__c WHERE Matched_Contact__c = :duplicateId];
        Integer affiliations = [SELECT COUNT() FROM HCP_Affiliation__c WHERE Contact__c = :duplicateId];
        Integer attendees = [SELECT COUNT() FROM Event_Attendee__c WHERE Contact__c = :duplicateId];

        Savepoint sp = Database.setSavepoint();
        try {
            foldAffiliations(masterId, duplicateId);
            foldAttendees(masterId, duplicateId);
            foldPairs(masterId, duplicateId, pairId);

            upd.setOptions(CaptureResolutionService.allowDuplicates());
            Database.update(upd, CaptureResolutionService.allowDuplicates());
            Database.MergeResult res = Database.merge(new Contact(Id = masterId), duplicateId, false);
            if (!res.isSuccess()) {
                List<String> errs = new List<String>();
                for (Database.Error e : res.getErrors()) {
                    errs.add(e.getMessage());
                }
                throw new MergeException('Merge failed: ' + String.join(errs, '; '));
            }

            fixKeysAfterMerge(masterId);
            // the HCO chosen as Account becomes the primary affiliation (the trigger then aligns AccountId)
            Id chosenAccount = upd.get('AccountId') != null ? (Id) upd.get('AccountId') : master.AccountId;
            List<HCP_Affiliation__c> chosen = [
                SELECT Id, Primary__c
                FROM HCP_Affiliation__c
                WHERE Contact__c = :masterId AND HCO__c = :chosenAccount AND HCO__c != NULL
                LIMIT 1
            ];
            if (!chosen.isEmpty() && !chosen[0].Primary__c) {
                update new HCP_Affiliation__c(Id = chosen[0].Id, Primary__c = true);
            } else {
                AffiliationService.sync(new Set<Id>{ masterId }, chosen.isEmpty() ? new Set<Id>() : new Set<Id>{ chosen[0].Id });
            }
            ConsentService.refreshContactSummary(new Set<Id>{ masterId });

            HCP_Merge__c audit = new HCP_Merge__c(
                Master_Contact__c = masterId,
                Master_Contact_Id__c = String.valueOf(masterId),
                Merged_Contact_Id__c = String.valueOf(duplicateId),
                Merged_Contact_Name__c = dup.Name == null ? null : dup.Name.left(121),
                Master_Before__c = masterBefore.left(32768),
                Merged_Snapshot__c = dupSnapshot.left(32768),
                Field_Choices__c = JSON.serialize(choiceLog).left(32768),
                Related_Summary__c = (consents + ' consents, ' + captures + ' captures, ' + affiliations + ' affiliations, ' + attendees + ' event attendances moved').left(255),
                Merged_By__c = UserInfo.getUserId(),
                Merged_At__c = System.now(),
                Duplicate_Pair__c = pairId
            );
            insert audit;
            return audit;
        } catch (Exception e) {
            Database.rollback(sp);
            throw e;
        }
    }

    /** Affiliations of the duplicate to an HCO the master already has are dropped (the master keeps its own). */
    private static void foldAffiliations(Id masterId, Id duplicateId) {
        Set<Id> masterHcos = new Set<Id>();
        Boolean masterHasPrimary = false;
        for (HCP_Affiliation__c a : [SELECT HCO__c, Primary__c FROM HCP_Affiliation__c WHERE Contact__c = :masterId]) {
            masterHcos.add(a.HCO__c);
            masterHasPrimary = masterHasPrimary || a.Primary__c;
        }
        List<HCP_Affiliation__c> drop = new List<HCP_Affiliation__c>();
        List<HCP_Affiliation__c> demote = new List<HCP_Affiliation__c>();
        for (HCP_Affiliation__c a : [SELECT Id, HCO__c, Primary__c FROM HCP_Affiliation__c WHERE Contact__c = :duplicateId]) {
            if (masterHcos.contains(a.HCO__c)) {
                drop.add(a);
            } else if (a.Primary__c && masterHasPrimary) {
                demote.add(new HCP_Affiliation__c(Id = a.Id, Primary__c = false));
            }
        }
        delete drop;
        update demote;
    }

    /** One attendance per event: when both attended, the master's record stays (no communications if either declined). */
    private static void foldAttendees(Id masterId, Id duplicateId) {
        Map<Id, Event_Attendee__c> masterByEvent = new Map<Id, Event_Attendee__c>();
        for (Event_Attendee__c a : [SELECT Id, Event__c, Communications_Allowed__c FROM Event_Attendee__c WHERE Contact__c = :masterId]) {
            masterByEvent.put(a.Event__c, a);
        }
        List<Event_Attendee__c> drop = new List<Event_Attendee__c>();
        List<Event_Attendee__c> keep = new List<Event_Attendee__c>();
        for (Event_Attendee__c a : [SELECT Id, Event__c, Communications_Allowed__c FROM Event_Attendee__c WHERE Contact__c = :duplicateId]) {
            Event_Attendee__c m = masterByEvent.get(a.Event__c);
            if (m != null) {
                drop.add(a);
                if (m.Communications_Allowed__c && !a.Communications_Allowed__c) {
                    keep.add(new Event_Attendee__c(Id = m.Id, Communications_Allowed__c = false));
                }
            }
        }
        delete drop;
        update keep;
    }

    /** The merged pair is closed; other pairs of the duplicate move to the master (or are dropped when the master already has them). */
    private static void foldPairs(Id masterId, Id duplicateId, Id pairId) {
        List<HCP_Duplicate_Pair__c> pairs = [
            SELECT Id, Contact_A__c, Contact_B__c, Pair_Key__c, Status__c
            FROM HCP_Duplicate_Pair__c
            WHERE Contact_A__c = :duplicateId OR Contact_B__c = :duplicateId
        ];
        Set<String> masterKeys = new Set<String>();
        for (HCP_Duplicate_Pair__c p : [SELECT Pair_Key__c FROM HCP_Duplicate_Pair__c WHERE Contact_A__c = :masterId OR Contact_B__c = :masterId]) {
            masterKeys.add(p.Pair_Key__c);
        }
        List<HCP_Duplicate_Pair__c> updates = new List<HCP_Duplicate_Pair__c>();
        List<HCP_Duplicate_Pair__c> drops = new List<HCP_Duplicate_Pair__c>();
        for (HCP_Duplicate_Pair__c p : pairs) {
            Id other = p.Contact_A__c == duplicateId ? p.Contact_B__c : p.Contact_A__c;
            if (p.Id == pairId || other == masterId) {
                updates.add(
                    new HCP_Duplicate_Pair__c(
                        Id = p.Id,
                        Status__c = DuplicateScanJob.STATUS_MERGED,
                        Decided_By__c = UserInfo.getUserId(),
                        Decided_At__c = System.now(),
                        Decision_Note__c = 'Merged into ' + masterId
                    )
                );
                continue;
            }
            if (other == null) {
                drops.add(p);
                continue;
            }
            String newKey = DuplicateScanJob.pairKey(masterId, other);
            if (masterKeys.contains(newKey)) {
                drops.add(p);
            } else {
                masterKeys.add(newKey);
                updates.add(
                    new HCP_Duplicate_Pair__c(
                        Id = p.Id,
                        Contact_A__c = p.Contact_A__c == duplicateId ? masterId : p.Contact_A__c,
                        Contact_B__c = p.Contact_B__c == duplicateId ? masterId : p.Contact_B__c,
                        Pair_Key__c = newKey
                    )
                );
            }
        }
        delete drops;
        update updates;
    }

    /** Re-keys the records that moved to the master (affiliations, attendances). */
    private static void fixKeysAfterMerge(Id masterId) {
        List<HCP_Affiliation__c> aff = new List<HCP_Affiliation__c>();
        for (HCP_Affiliation__c a : [SELECT Id, HCO__c, Affiliation_Key__c FROM HCP_Affiliation__c WHERE Contact__c = :masterId]) {
            String k = AffiliationService.key(masterId, a.HCO__c);
            if (a.Affiliation_Key__c != k) {
                aff.add(new HCP_Affiliation__c(Id = a.Id, Affiliation_Key__c = k));
            }
        }
        update aff;
        List<Event_Attendee__c> att = new List<Event_Attendee__c>();
        for (Event_Attendee__c a : [SELECT Id, Event__c, Attendee_Key__c FROM Event_Attendee__c WHERE Contact__c = :masterId]) {
            String k = CaptureResolutionService.attendeeKey(a.Event__c, masterId);
            if (a.Attendee_Key__c != k) {
                att.add(new Event_Attendee__c(Id = a.Id, Attendee_Key__c = k));
            }
        }
        update att;
    }

    // ------------------------------------------------------------ evidence after merges

    /**
     * Contact Ids a consent of this HCP may have been recorded with: the HCP itself plus every HCP
     * merged into it, directly or through earlier merges (up to 10 levels), with the merge that moved it.
     */
    public static Map<String, HCP_Merge__c> verificationContactIds(Id contactId) {
        Map<String, HCP_Merge__c> out = new Map<String, HCP_Merge__c>();
        if (contactId == null) {
            return out;
        }
        Set<String> frontier = new Set<String>{ String.valueOf(contactId) };
        Set<String> seen = new Set<String>(frontier);
        for (Integer depth = 0; depth < 10 && !frontier.isEmpty(); depth++) {
            Set<String> next = new Set<String>();
            for (HCP_Merge__c m : [
                SELECT Id, Name, Master_Contact_Id__c, Merged_Contact_Id__c, Merged_Contact_Name__c, Merged_At__c, Merged_By__r.Name
                FROM HCP_Merge__c
                WHERE Master_Contact_Id__c IN :frontier
            ]) {
                if (!seen.contains(m.Merged_Contact_Id__c)) {
                    seen.add(m.Merged_Contact_Id__c);
                    next.add(m.Merged_Contact_Id__c);
                    out.put(m.Merged_Contact_Id__c, m);
                }
            }
            frontier = next;
        }
        return out;
    }
}
