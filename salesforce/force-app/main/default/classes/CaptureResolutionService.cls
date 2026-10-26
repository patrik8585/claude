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
                Hospital__c,
                Department__c,
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
                Consent__c,
                Test_Data_Set__c
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

    /**
     * Creates a Contact for each capture and sets Matched_Contact__c.
     * The Contact's Account is the department (captured, or the hospital department fitting the specialty)
     * or the hospital, resolved from the captured organisation text / email domain. A primary
     * HCP_Affiliation__c is created for it. When no hospital is known, the Contact goes under
     * "HCPs - organisation unknown" (no Hospital Account is created from free text).
     */
    public static void createContactsFor(List<Capture__c> captures) {
        HcoDirectory dir = HcoDirectory.get();
        Database.DMLOptions dml = allowDuplicates();
        Id unknownId = null;
        Map<Id, Id> hcoByCapture = new Map<Id, Id>();
        for (Capture__c c : captures) {
            if (c.Hospital__c == null && c.Department__c != null) {
                c.Hospital__c = dir.hospitalOf(c.Department__c);
            }
            if (c.Hospital__c == null) {
                c.Hospital__c = dir.resolve(c.Organisation__c, c.Email__c).hospitalId;
            }
            if (c.Department__c == null && c.Hospital__c != null) {
                c.Department__c = dir.departmentFor(c.Hospital__c, c.Specialty__c);
            }
            Id hco = c.Department__c != null ? c.Department__c : c.Hospital__c;
            if (hco != null) {
                hcoByCapture.put(c.Id, hco);
            }
        }
        if (hcoByCapture.size() < captures.size()) {
            unknownId = unknownOrganisationId(captures[0].OwnerId);
        }
        List<Contact> contacts = new List<Contact>();
        for (Capture__c c : captures) {
            Id hco = hcoByCapture.get(c.Id);
            Id hospitalId = dir.hospitalOf(hco);
            String city = c.City__c;
            if (String.isBlank(city) && hospitalId != null) {
                city = dir.hospitals.get(hospitalId).BillingCity;
            }
            Contact ct = new Contact(
                FirstName = c.First_Name__c,
                LastName = String.isBlank(c.Last_Name__c) ? 'Unknown' : c.Last_Name__c,
                Email = c.Email__c,
                Specialty__c = c.Specialty__c,
                MailingCity = city,
                Registration_Number__c = c.Registration_Number__c,
                AccountId = hco == null ? unknownId : hco,
                OwnerId = c.OwnerId,
                Territory__c = c.Captured_By__c == null ? null : c.Captured_By__r.Territory__c,
                Consent_Status__c = CaptureConstants.HCP_NONE,
                Test_Data_Set__c = c.Test_Data_Set__c
            );
            ct.setOptions(dml);
            contacts.add(ct);
        }
        Database.insert(contacts, dml);
        List<HCP_Affiliation__c> affiliations = new List<HCP_Affiliation__c>();
        for (Integer i = 0; i < captures.size(); i++) {
            captures[i].Matched_Contact__c = contacts[i].Id;
            Id hco = hcoByCapture.get(captures[i].Id);
            if (hco != null) {
                affiliations.add(
                    new HCP_Affiliation__c(Contact__c = contacts[i].Id, HCO__c = hco, Primary__c = true, Start_Date__c = Date.today())
                );
            }
        }
        if (!affiliations.isEmpty()) {
            insert affiliations;
        }
    }

    private static Id unknownOrganisationId(Id ownerId) {
        List<Account> rows = [SELECT Id FROM Account WHERE Name = :CaptureConstants.UNKNOWN_ORGANISATION ORDER BY CreatedDate ASC LIMIT 1];
        if (!rows.isEmpty()) {
            return rows[0].Id;
        }
        Account a = new Account(Name = CaptureConstants.UNKNOWN_ORGANISATION, OwnerId = ownerId);
        Database.insert(a, allowDuplicates());
        return a.Id;
    }

    public static Database.DMLOptions allowDuplicates() {
        Database.DMLOptions dml = new Database.DMLOptions();
        dml.DuplicateRuleHeader.allowSave = true;
        dml.DuplicateRuleHeader.runAsCurrentUser = false;
        dml.OptAllOrNone = true;
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
                Opt_In_Method__c = signed
                    ? CaptureConstants.METHOD_SIGNATURE
                    : (c.Consent_Method__c == CaptureConstants.METHOD_REGISTRATION ? CaptureConstants.METHOD_REGISTRATION : CaptureConstants.METHOD_EMAIL),
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
                    Hospital__c = c.Hospital__c,
                    Department__c = c.Department__c,
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

    /**
     * EventId-ContactId with 18-character Ids: Attendee_Key__c is unique case-insensitively,
     * and two 15-character Ids can differ only by case.
     */
    public static String attendeeKey(Id eventId, Id contactId) {
        return String.valueOf(eventId) + '-' + String.valueOf(contactId);
    }

    /**
     * One attendee per event + HCP. An imported registration creates it as Registered (Registered__c = true);
     * any event-day capture (rep, kiosk, self-scan) makes it Attended, and a later registration import never
     * turns an Attended back into Registered. Communications are allowed when this capture gives consent or the
     * HCP already has a confirmed consent: an event where the HCP does not answer never removes a valid opt-in.
     */
    private static void upsertAttendees(List<Capture__c> captures) {
        Set<Id> matchedContacts = new Set<Id>();
        for (Capture__c c : captures) {
            if (c.Event__c != null && c.Matched_Contact__c != null) {
                matchedContacts.add(c.Matched_Contact__c);
            }
        }
        if (matchedContacts.isEmpty()) {
            return;
        }
        Set<Id> withConsent = new Set<Id>();
        for (Consent__c k : [
            SELECT Contact__c
            FROM Consent__c
            WHERE Contact__c IN :matchedContacts AND Status__c = :CaptureConstants.CONSENT_CONFIRMED
        ]) {
            withConsent.add(k.Contact__c);
        }
        Map<String, Event_Attendee__c> byKey = new Map<String, Event_Attendee__c>();
        for (Capture__c c : captures) {
            if (c.Event__c == null || c.Matched_Contact__c == null) {
                continue;
            }
            String key = attendeeKey(c.Event__c, c.Matched_Contact__c);
            Boolean registration = c.Channel__c == CaptureConstants.CHANNEL_REGISTRATION;
            Boolean gives = c.Consent_Given__c == true &&
                c.Consent_Method__c != CaptureConstants.METHOD_DECLINED &&
                c.Opt_In_Status__c != CaptureConstants.OPTIN_DECLINED;
            Event_Attendee__c a = byKey.get(key);
            if (a == null) {
                a = new Event_Attendee__c(
                    Event__c = c.Event__c,
                    Contact__c = c.Matched_Contact__c,
                    Attendee_Key__c = key,
                    Attendance_Status__c = CaptureConstants.ATTENDANCE_REGISTERED,
                    Registered__c = false,
                    Communications_Allowed__c = withConsent.contains(c.Matched_Contact__c)
                );
                byKey.put(key, a);
            }
            if (registration) {
                a.Registered__c = true;
                if (a.Source_Capture__c == null) {
                    a.Source_Capture__c = c.Id;
                }
            } else {
                a.Attendance_Status__c = CaptureConstants.ATTENDANCE_ATTENDED;
                a.Source_Capture__c = c.Id;
            }
            a.Communications_Allowed__c = a.Communications_Allowed__c || gives;
        }
        // Existing attendees are found by event + HCP (older rows may carry a 15-character key)
        // and updated without touching the master-detail field; their key is rewritten.
        Set<Id> eventIds = new Set<Id>();
        for (Event_Attendee__c a : byKey.values()) {
            eventIds.add(a.Event__c);
        }
        Map<String, Event_Attendee__c> existing = new Map<String, Event_Attendee__c>();
        for (Event_Attendee__c a : [
            SELECT Id, Event__c, Contact__c, Attendance_Status__c, Registered__c, Communications_Allowed__c, Source_Capture__c
            FROM Event_Attendee__c
            WHERE Event__c IN :eventIds AND Contact__c IN :matchedContacts
        ]) {
            existing.put(attendeeKey(a.Event__c, a.Contact__c), a);
        }
        List<Event_Attendee__c> inserts = new List<Event_Attendee__c>();
        List<Event_Attendee__c> updates = new List<Event_Attendee__c>();
        for (String key : byKey.keySet()) {
            Event_Attendee__c a = byKey.get(key);
            Event_Attendee__c old = existing.get(key);
            if (old == null) {
                inserts.add(a);
                continue;
            }
            Boolean attended = old.Attendance_Status__c == CaptureConstants.ATTENDANCE_ATTENDED ||
                a.Attendance_Status__c == CaptureConstants.ATTENDANCE_ATTENDED;
            updates.add(
                new Event_Attendee__c(
                    Id = old.Id,
                    Attendee_Key__c = key,
                    Attendance_Status__c = attended ? CaptureConstants.ATTENDANCE_ATTENDED : CaptureConstants.ATTENDANCE_REGISTERED,
                    Registered__c = old.Registered__c || a.Registered__c,
                    Source_Capture__c = a.Attendance_Status__c == CaptureConstants.ATTENDANCE_ATTENDED || old.Source_Capture__c == null
                        ? a.Source_Capture__c
                        : old.Source_Capture__c,
                    Communications_Allowed__c = old.Communications_Allowed__c || a.Communications_Allowed__c
                )
            );
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
