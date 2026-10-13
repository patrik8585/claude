/**
 * Completes a capture once its HCP is known (auto-match, new HCP or steward decision):
 * consent record (unless reused / declined), event attendee, follow-up task link,
 * signature file link, Contact consent summary.
 */
public without sharing class CaptureResolutionService {
    public static List<Capture__c> loadCaptures(Set<Id> ids) {
        return [
            SELECT
                Id,
                Name,
                OwnerId,
                Owner.Type,
                CreatedById,
                CreatedBy.UserType,
                First_Name__c,
                Last_Name__c,
                Email__c,
                Specialty__c,
                City__c,
                Organisation__c,
                Registration_Number__c,
                Registration_Key__c,
                Channel__c,
                Event__c,
                Event__r.OwnerId,
                Event__r.Name,
                Captured_By__c,
                Captured_By__r.Territory__c,
                Captured_By_Name__c,
                Captured_At__c,
                Consent_Given__c,
                Consent_Method__c,
                Opt_In_Status__c,
                Opt_In_Confirmed_At__c,
                Consent_Text_Version__c,
                Signature_Captured__c,
                Signature_Hash__c,
                Signature_Copy_Sent__c,
                Capture_Device__c,
                HCP_Selected_By_Rep__c,
                Processing_Stage__c,
                Matching_Status__c,
                Match_Rule__c,
                Matched_Contact__c,
                Matched_By__c,
                Consent__c
            FROM Capture__c
            WHERE Id IN :ids
        ];
    }

    /** Captures submitted on the public site belong to the event owner, never to the guest user. */
    public static void assignInternalOwners(List<Capture__c> captures) {
        for (Capture__c c : captures) {
            Boolean guestCreated = c.CreatedBy != null && c.CreatedBy.UserType == 'Guest';
            Boolean nonUserOwner = c.Owner != null && c.Owner.Type != 'User';
            if ((guestCreated || nonUserOwner) && c.Event__c != null && c.Event__r.OwnerId != null) {
                c.OwnerId = c.Event__r.OwnerId;
            }
        }
    }

    // ------------------------------------------------------------ new HCPs

    /** Creates an Account (by organisation name) and a Contact for each capture and sets Matched_Contact__c. */
    public static void createContactsFor(List<Capture__c> captures) {
        Set<String> orgNames = new Set<String>{ CaptureConstants.UNKNOWN_ORGANISATION };
        for (Capture__c c : captures) {
            if (String.isNotBlank(c.Organisation__c)) {
                orgNames.add(c.Organisation__c.trim());
            }
        }
        Map<String, Id> accountByName = new Map<String, Id>();
        for (Account a : [SELECT Id, Name FROM Account WHERE Name IN :orgNames ORDER BY CreatedDate ASC]) {
            if (!accountByName.containsKey(a.Name.toLowerCase())) {
                accountByName.put(a.Name.toLowerCase(), a.Id);
            }
        }
        Database.DMLOptions dml = allowDuplicates();
        Map<String, Account> newAccounts = new Map<String, Account>();
        for (Capture__c c : captures) {
            String org = String.isBlank(c.Organisation__c) ? CaptureConstants.UNKNOWN_ORGANISATION : c.Organisation__c.trim();
            if (!accountByName.containsKey(org.toLowerCase()) && !newAccounts.containsKey(org.toLowerCase())) {
                Account a = new Account(Name = org, OwnerId = c.OwnerId);
                a.setOptions(dml);
                newAccounts.put(org.toLowerCase(), a);
            }
        }
        if (!newAccounts.isEmpty()) {
            insert newAccounts.values();
            for (String k : newAccounts.keySet()) {
                accountByName.put(k, newAccounts.get(k).Id);
            }
        }
        List<Contact> contacts = new List<Contact>();
        for (Capture__c c : captures) {
            String org = String.isBlank(c.Organisation__c) ? CaptureConstants.UNKNOWN_ORGANISATION : c.Organisation__c.trim();
            Contact ct = new Contact(
                FirstName = c.First_Name__c,
                LastName = String.isBlank(c.Last_Name__c) ? 'Unknown' : c.Last_Name__c,
                Email = c.Email__c,
                Specialty__c = c.Specialty__c,
                MailingCity = c.City__c,
                Registration_Number__c = c.Registration_Number__c,
                AccountId = accountByName.get(org.toLowerCase()),
                OwnerId = c.OwnerId,
                Territory__c = c.Captured_By__c == null ? null : c.Captured_By__r.Territory__c,
                Consent_Status__c = CaptureConstants.HCP_NONE
            );
            ct.setOptions(dml);
            contacts.add(ct);
        }
        insert contacts;
        for (Integer i = 0; i < captures.size(); i++) {
            captures[i].Matched_Contact__c = contacts[i].Id;
        }
    }

    public static Database.DMLOptions allowDuplicates() {
        Database.DMLOptions dml = new Database.DMLOptions();
        dml.DuplicateRuleHeader.allowSave = true;
        dml.DuplicateRuleHeader.runAsCurrentUser = false;
        return dml;
    }

    // ------------------------------------------------------------ completion

    public static void complete(List<Capture__c> captures) {
        ConsentCaptureConfig.ConsentText text = ConsentCaptureConfig.activeConsentText();
        Set<Id> contactIds = new Set<Id>();
        for (Capture__c c : captures) {
            contactIds.add(c.Matched_Contact__c);
        }

        // Latest confirmed consent per contact, used when the rep reused an existing consent.
        Map<Id, Consent__c> existingByContact = new Map<Id, Consent__c>();
        for (Consent__c k : [
            SELECT Id, Contact__c, Gigya_Status__c
            FROM Consent__c
            WHERE Contact__c IN :contactIds AND Status__c = :CaptureConstants.CONSENT_CONFIRMED
            ORDER BY Confirmed_At__c DESC
        ]) {
            if (!existingByContact.containsKey(k.Contact__c)) {
                existingByContact.put(k.Contact__c, k);
            }
        }

        Map<Id, Consent__c> newConsentByCapture = new Map<Id, Consent__c>();
        for (Capture__c c : captures) {
            if (c.Consent_Method__c == CaptureConstants.METHOD_DECLINED || c.Opt_In_Status__c == CaptureConstants.OPTIN_DECLINED) {
                c.Processing_Stage__c = CaptureConstants.STAGE_NO_CONSENT;
                continue;
            }
            if (c.Consent_Method__c == CaptureConstants.METHOD_EXISTING) {
                Consent__c existing = existingByContact.get(c.Matched_Contact__c);
                if (existing != null) {
                    c.Consent__c = existing.Id;
                    c.Processing_Stage__c = existing.Gigya_Status__c == CaptureConstants.GIGYA_SENT
                        ? CaptureConstants.STAGE_SENT
                        : CaptureConstants.STAGE_CONSENT_CREATED;
                } else {
                    c.Processing_Stage__c = CaptureConstants.STAGE_MATCHED;
                }
                continue;
            }
            if (!c.Consent_Given__c) {
                c.Processing_Stage__c = CaptureConstants.STAGE_NO_CONSENT;
                continue;
            }
            Boolean confirmed = c.Opt_In_Status__c == CaptureConstants.OPTIN_CONFIRMED;
            Boolean signed = c.Consent_Method__c == CaptureConstants.METHOD_SIGNATURE;
            Consent__c k = new Consent__c(
                Contact__c = c.Matched_Contact__c,
                OwnerId = c.OwnerId,
                Consent_Type__c = CaptureConstants.CONSENT_TYPE_EMAIL,
                Status__c = confirmed ? CaptureConstants.CONSENT_CONFIRMED : CaptureConstants.CONSENT_PENDING,
                Channel__c = c.Channel__c,
                Captured_At__c = c.Captured_At__c,
                Confirmed_At__c = confirmed ? (c.Opt_In_Confirmed_At__c == null ? System.now() : c.Opt_In_Confirmed_At__c) : null,
                Consent_Text_Version__c = c.Consent_Text_Version__c,
                Consent_Text__c = (c.Consent_Text_Version__c == null || c.Consent_Text_Version__c == text.version) ? text.body : null,
                Captured_By__c = c.Captured_By__c,
                Captured_By_Name__c = c.Captured_By_Name__c,
                Opt_In_Method__c = signed ? CaptureConstants.METHOD_SIGNATURE : CaptureConstants.METHOD_EMAIL,
                Signature_Captured__c = c.Signature_Captured__c,
                Signature_Hash__c = c.Signature_Hash__c,
                Signature_Copy_Sent__c = c.Signature_Copy_Sent__c,
                Capture_Device__c = c.Capture_Device__c,
                Matched_By__c = c.Matched_By__c,
                Source_Capture__c = c.Id,
                Event__c = c.Event__c,
                Gigya_Status__c = confirmed ? CaptureConstants.GIGYA_QUEUED : CaptureConstants.GIGYA_WAITING
            );
            k.Evidence_Hash__c = ConsentService.evidenceHash(k);
            newConsentByCapture.put(c.Id, k);
        }
        if (!newConsentByCapture.isEmpty()) {
            insert newConsentByCapture.values();
            for (Capture__c c : captures) {
                Consent__c k = newConsentByCapture.get(c.Id);
                if (k != null) {
                    c.Consent__c = k.Id;
                    c.Processing_Stage__c = CaptureConstants.STAGE_CONSENT_CREATED;
                }
            }
        }

        upsertAttendees(captures);
        linkTasks(captures);
        linkSignatures(captures, newConsentByCapture);

        List<Capture__c> updates = new List<Capture__c>();
        for (Capture__c c : captures) {
            updates.add(
                new Capture__c(
                    Id = c.Id,
                    OwnerId = c.OwnerId,
                    Matched_Contact__c = c.Matched_Contact__c,
                    Matching_Status__c = c.Matching_Status__c,
                    Match_Rule__c = c.Match_Rule__c,
                    Matched_By__c = c.Matched_By__c,
                    Consent__c = c.Consent__c,
                    Processing_Stage__c = c.Processing_Stage__c,
                    Processing_Error__c = null
                )
            );
        }
        update updates;
        ConsentService.refreshContactSummary(contactIds);
    }

    private static void upsertAttendees(List<Capture__c> captures) {
        Map<String, Event_Attendee__c> byKey = new Map<String, Event_Attendee__c>();
        for (Capture__c c : captures) {
            if (c.Event__c == null || c.Matched_Contact__c == null) {
                continue;
            }
            String key = String.valueOf(c.Event__c).left(15) + '-' + String.valueOf(c.Matched_Contact__c).left(15);
            byKey.put(
                key,
                new Event_Attendee__c(
                    Event__c = c.Event__c,
                    Contact__c = c.Matched_Contact__c,
                    Source_Capture__c = c.Id,
                    Attendee_Key__c = key,
                    Attendance_Status__c = 'Attended',
                    Communications_Allowed__c = c.Consent_Method__c != CaptureConstants.METHOD_DECLINED &&
                        c.Opt_In_Status__c != CaptureConstants.OPTIN_DECLINED
                )
            );
        }
        if (byKey.isEmpty()) {
            return;
        }
        // Existing attendees are updated without touching the master-detail field.
        Map<String, Event_Attendee__c> existing = new Map<String, Event_Attendee__c>();
        for (Event_Attendee__c a : [SELECT Id, Attendee_Key__c FROM Event_Attendee__c WHERE Attendee_Key__c IN :byKey.keySet()]) {
            existing.put(a.Attendee_Key__c, a);
        }
        List<Event_Attendee__c> inserts = new List<Event_Attendee__c>();
        List<Event_Attendee__c> updates = new List<Event_Attendee__c>();
        for (String key : byKey.keySet()) {
            Event_Attendee__c a = byKey.get(key);
            if (existing.containsKey(key)) {
                updates.add(
                    new Event_Attendee__c(
                        Id = existing.get(key).Id,
                        Source_Capture__c = a.Source_Capture__c,
                        Communications_Allowed__c = a.Communications_Allowed__c
                    )
                );
            } else {
                inserts.add(a);
            }
        }
        insert inserts;
        update updates;
    }

    private static void linkTasks(List<Capture__c> captures) {
        Map<Id, Id> contactByCapture = new Map<Id, Id>();
        for (Capture__c c : captures) {
            if (c.Matched_Contact__c != null) {
                contactByCapture.put(c.Id, c.Matched_Contact__c);
            }
        }
        if (contactByCapture.isEmpty()) {
            return;
        }
        List<Task> tasks = [SELECT Id, WhatId FROM Task WHERE WhatId IN :contactByCapture.keySet() AND WhoId = NULL];
        for (Task t : tasks) {
            t.WhoId = contactByCapture.get(t.WhatId);
        }
        if (!tasks.isEmpty()) {
            Database.update(tasks, false);
        }
    }

    private static void linkSignatures(List<Capture__c> captures, Map<Id, Consent__c> consentByCapture) {
        Set<Id> signed = new Set<Id>();
        for (Capture__c c : captures) {
            if (c.Signature_Captured__c && consentByCapture.containsKey(c.Id)) {
                signed.add(c.Id);
            }
        }
        if (signed.isEmpty()) {
            return;
        }
        try {
            List<ContentDocumentLink> links = new List<ContentDocumentLink>();
            for (ContentDocumentLink l : [
                SELECT ContentDocumentId, LinkedEntityId
                FROM ContentDocumentLink
                WHERE LinkedEntityId IN :signed
            ]) {
                links.add(
                    new ContentDocumentLink(
                        ContentDocumentId = l.ContentDocumentId,
                        LinkedEntityId = consentByCapture.get(l.LinkedEntityId).Id,
                        ShareType = 'V'
                    )
                );
            }
            Database.insert(links, false);
        } catch (Exception e) {
            // The signature stays on the capture; the consent keeps Signature_Captured__c = true.
            System.debug(LoggingLevel.WARN, 'Signature link failed: ' + e.getMessage());
        }
    }
}
