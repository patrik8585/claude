/**
 * Keeps HCP affiliations consistent:
 *   - Affiliation_Key__c = ContactId-AccountId (unique: no duplicate affiliation);
 *   - exactly one primary affiliation per HCP with active affiliations (the one just marked primary wins;
 *     when none is left, the most recent active one is promoted);
 *   - Contact.AccountId = the HCO of the primary active affiliation.
 */
public without sharing class AffiliationService {
    private static Boolean running = false;

    public static String key(Id contactId, Id hcoId) {
        return String.valueOf(contactId) + '-' + String.valueOf(hcoId);
    }

    public static void beforeSave(List<HCP_Affiliation__c> rows) {
        for (HCP_Affiliation__c a : rows) {
            if (a.Contact__c != null && a.HCO__c != null) {
                a.Affiliation_Key__c = key(a.Contact__c, a.HCO__c);
            }
        }
    }

    public static void afterSave(List<HCP_Affiliation__c> rows, Map<Id, HCP_Affiliation__c> oldMap) {
        if (running) {
            return;
        }
        Set<Id> contactIds = new Set<Id>();
        Set<Id> winners = new Set<Id>();
        for (HCP_Affiliation__c a : rows) {
            contactIds.add(a.Contact__c);
            HCP_Affiliation__c old = oldMap == null ? null : oldMap.get(a.Id);
            if (a.Primary__c && (old == null || !old.Primary__c || old.HCO__c != a.HCO__c)) {
                winners.add(a.Id);
            }
            if (old != null && old.Contact__c != a.Contact__c) {
                contactIds.add(old.Contact__c);
            }
        }
        sync(contactIds, winners);
    }

    public static void afterDelete(List<HCP_Affiliation__c> rows) {
        if (running) {
            return;
        }
        Set<Id> contactIds = new Set<Id>();
        for (HCP_Affiliation__c a : rows) {
            contactIds.add(a.Contact__c);
        }
        sync(contactIds, new Set<Id>());
    }

    /** Enforces one primary per HCP and sets Contact.AccountId to the primary HCO. */
    public static void sync(Set<Id> contactIds, Set<Id> preferredPrimaryIds) {
        contactIds.remove(null);
        if (contactIds.isEmpty()) {
            return;
        }
        Map<Id, List<HCP_Affiliation__c>> byContact = new Map<Id, List<HCP_Affiliation__c>>();
        for (HCP_Affiliation__c a : [
            SELECT Id, Contact__c, HCO__c, Primary__c, Active__c, LastModifiedDate
            FROM HCP_Affiliation__c
            WHERE Contact__c IN :contactIds
            ORDER BY LastModifiedDate DESC
        ]) {
            if (!byContact.containsKey(a.Contact__c)) {
                byContact.put(a.Contact__c, new List<HCP_Affiliation__c>());
            }
            byContact.get(a.Contact__c).add(a);
        }
        List<HCP_Affiliation__c> unset = new List<HCP_Affiliation__c>();
        List<HCP_Affiliation__c> promote = new List<HCP_Affiliation__c>();
        Map<Id, Id> accountByContact = new Map<Id, Id>();
        for (Id cid : byContact.keySet()) {
            HCP_Affiliation__c primary = null;
            for (HCP_Affiliation__c a : byContact.get(cid)) {
                if (a.Primary__c && preferredPrimaryIds.contains(a.Id)) {
                    primary = a;
                    break;
                }
            }
            if (primary == null) {
                for (HCP_Affiliation__c a : byContact.get(cid)) {
                    if (a.Primary__c && a.Active__c) {
                        primary = a;
                        break;
                    }
                }
            }
            if (primary == null) {
                // no primary left (e.g. it was deleted or ended): promote the most recent active affiliation
                for (HCP_Affiliation__c a : byContact.get(cid)) {
                    if (a.Active__c) {
                        primary = a;
                        promote.add(new HCP_Affiliation__c(Id = a.Id, Primary__c = true));
                        break;
                    }
                }
            }
            for (HCP_Affiliation__c a : byContact.get(cid)) {
                if (a.Primary__c && primary != null && a.Id != primary.Id) {
                    unset.add(new HCP_Affiliation__c(Id = a.Id, Primary__c = false));
                }
            }
            if (primary != null) {
                accountByContact.put(cid, primary.HCO__c);
            }
        }
        List<Contact> updates = new List<Contact>();
        for (Contact c : [SELECT Id, AccountId FROM Contact WHERE Id IN :accountByContact.keySet()]) {
            Id target = accountByContact.get(c.Id);
            if (target != null && c.AccountId != target) {
                Contact u = new Contact(Id = c.Id, AccountId = target);
                u.setOptions(CaptureResolutionService.allowDuplicates());
                updates.add(u);
            }
        }
        running = true;
        try {
            if (!unset.isEmpty()) {
                update unset;
            }
            if (!promote.isEmpty()) {
                update promote;
            }
            if (!updates.isEmpty()) {
                update updates;
            }
        } finally {
            running = false;
        }
    }
}
