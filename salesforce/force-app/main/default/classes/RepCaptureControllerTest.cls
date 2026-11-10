@IsTest
private class RepCaptureControllerTest {
    @TestSetup
    static void setup() {
        ConsentTestFactory.settings();
        ConsentTestFactory.event();
        Contact ferri = ConsentTestFactory.contact('Marco', 'Ferri', 'marco.ferri@policlinico-example.it', 'Paediatrics', 'Milan', 'MI-20418');
        ConsentTestFactory.confirmedConsent(ferri.Id);
        ConsentTestFactory.contact('Elena', 'Greco', 'elena.greco@asst-example.it', 'Paediatrics', 'Milan', 'MI-22764');
        Contact conti = ConsentTestFactory.contact('Paolo', 'Conti', 'paolo.conti@aosp-example.it', 'Paediatrics', 'Bologna', 'BO-09821');
        conti.Consent_Status__c = CaptureConstants.HCP_OPTOUT;
        update conti;
        Contact bianchi = ConsentTestFactory.contact('Maria', 'Bianchi', 'm.bianchi@gaslini-example.it', 'Paediatrics', 'Genoa', 'GE-11873');
        bianchi.Territory__c = 'IT-PED-02';
        update bianchi;
    }

    private static Event__c ev() {
        return [SELECT Id FROM Event__c LIMIT 1];
    }

    private static Id contactId(String lastName) {
        return [SELECT Id FROM Contact WHERE LastName = :lastName].Id;
    }

    @IsTest
    static void contextAndSearch() {
        User rep = ConsentTestFactory.user('HCP_Consent_Rep');
        System.runAs(rep) {
            RepCaptureController.RepContext ctx = RepCaptureController.getContext();
            Assert.areEqual(1, ctx.events.size());
            Assert.isTrue(ctx.events[0].live);
            Assert.areEqual(ConsentTestFactory.TERRITORY, ctx.territory);
            Assert.isNotNull(ctx.consent.question);

            List<RepCaptureController.HcpResult> res = RepCaptureController.searchHcps('Ferri', ev().Id);
            Assert.areEqual(1, res.size());
            Assert.areEqual('valid', res[0].consentStatus);
            Assert.areEqual('optout', RepCaptureController.searchHcps('conti', ev().Id)[0].consentStatus);
            Assert.areEqual('none', RepCaptureController.searchHcps('MI22764', ev().Id)[0].consentStatus);
            Assert.areEqual(0, RepCaptureController.searchHcps('x', ev().Id).size());
            Assert.areEqual(0, RepCaptureController.searchHcps('Nobody', ev().Id).size());

            // HCPs outside the rep's territory are found too, flagged and listed after the own territory
            List<RepCaptureController.HcpResult> other = RepCaptureController.searchHcps('Bianchi', ev().Id);
            Assert.areEqual(1, other.size(), 'out-of-territory HCPs must be searchable');
            Assert.isFalse(other[0].inMyTerritory, 'flagged as other territory');
            List<RepCaptureController.HcpResult> mixed = RepCaptureController.searchHcps('Ma', ev().Id);
            Assert.isTrue(mixed[0].inMyTerritory, 'own territory first');
            Assert.isFalse(mixed[mixed.size() - 1].inMyTerritory, 'other territory last');
        }
    }

    @IsTest
    static void addKnownHcpAllMethods() {
        User rep = ConsentTestFactory.user('HCP_Consent_Rep');
        Id evId = ev().Id;
        System.runAs(rep) {
            RepCaptureController.SaveResult existing = RepCaptureController.addKnownHcp(
                evId,
                contactId('Ferri'),
                null,
                null,
                'Test browser',
                new List<String>{ 'Allergy', 'GI', 'Not a therapeutic area', 'Allergy' }
            );
            Assert.isTrue(existing.message.contains('on file'));

            RepCaptureController.SaveResult signed = RepCaptureController.addKnownHcp(evId, contactId('Greco'), 'sign', ConsentTestFactory.signature(), 'Test browser', null);
            Assert.isTrue(signed.message.startsWith('Signed'));

            RepCaptureController.SaveResult mailed = RepCaptureController.addKnownHcp(evId, contactId('Conti'), 'declined', null, 'Test browser', null);
            Assert.isTrue(mailed.message.contains('declined'));

            Boolean blocked = false;
            try {
                RepCaptureController.addKnownHcp(evId, contactId('Conti'), 'email', null, 'Test browser', null);
            } catch (AuraHandledException e) {
                blocked = true;
            }
            Assert.isTrue(blocked, 'opted-out HCPs cannot get an email link');

            Boolean noSignature = false;
            try {
                RepCaptureController.addKnownHcp(evId, contactId('Greco'), 'sign', null, 'Test browser', null);
            } catch (AuraHandledException e) {
                noSignature = true;
            }
            Assert.isTrue(noSignature);

            Assert.areEqual(1, RepCaptureController.searchHcps('Ferri', evId).size());
            Assert.isTrue(RepCaptureController.searchHcps('Ferri', evId)[0].alreadyAdded);

            List<RepCaptureController.MyCapture> mine = RepCaptureController.getMyCapturesToday();
            Assert.areEqual(3, mine.size());
        }
        Assert.areEqual(
            'Allergy;GI',
            [SELECT Therapeutic_Area__c FROM Capture__c WHERE Last_Name__c = 'Ferri'].Therapeutic_Area__c,
            'known values kept once, unknown values ignored'
        );
        Capture__c signedCap = [
            SELECT Consent_Method__c, Opt_In_Status__c, Signature_Captured__c, HCP_Selected_By_Rep__c, Captured_By__c, Signature_Hash__c, Capture_Device__c
            FROM Capture__c
            WHERE Last_Name__c = 'Greco'
        ];
        Assert.areEqual(CaptureConstants.METHOD_SIGNATURE, signedCap.Consent_Method__c);
        Assert.areEqual(CaptureConstants.OPTIN_CONFIRMED, signedCap.Opt_In_Status__c);
        Assert.isTrue(signedCap.Signature_Captured__c);
        Assert.areEqual(64, signedCap.Signature_Hash__c.length(), 'SHA-256 of the signature image');
        Assert.areEqual('Test browser', signedCap.Capture_Device__c);
        Assert.isTrue(signedCap.HCP_Selected_By_Rep__c);
        Assert.areEqual(rep.Id, signedCap.Captured_By__c);
        Assert.areEqual(1, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :signedCap.Id], 'signature file linked to the capture');
    }

    @IsTest
    static void emailLinkForKnownHcp() {
        User rep = ConsentTestFactory.user('HCP_Consent_Rep');
        Id evId = ev().Id;
        System.runAs(rep) {
            RepCaptureController.SaveResult r = RepCaptureController.addKnownHcp(evId, contactId('Greco'), 'email', null, 'Test browser', null);
            Assert.isNotNull(r.captureName);
        }
        Capture__c c = [SELECT Opt_In_Status__c, Confirmation_Token_Hash__c, Confirmation_Email_Status__c FROM Capture__c];
        Assert.areEqual(CaptureConstants.OPTIN_PENDING, c.Opt_In_Status__c);
        Assert.isNotNull(c.Confirmation_Token_Hash__c);
        Assert.areNotEqual(CaptureConstants.EMAIL_NOT_REQUIRED, c.Confirmation_Email_Status__c);
    }

    @IsTest
    static void walkInWithTaskAndExtraction() {
        User rep = ConsentTestFactory.user('HCP_Consent_Rep');
        Id evId = ev().Id;
        System.runAs(rep) {
            NotesExtractionService.Result x = RepCaptureController.extractFromNotes(
                'Dr. Maria Bianchi, paediatrician at Gaslini Genoa, interested in product X, call back in November. Email maria.bianchi@gmail.com'
            );
            RepCaptureController.WalkIn w = new RepCaptureController.WalkIn();
            w.firstName = x.firstName;
            w.lastName = x.lastName;
            w.email = x.email;
            w.specialty = x.specialty;
            w.city = x.city;
            w.organisation = x.organisation;
            w.interest = x.interest;
            w.notes = 'notes';
            w.therapeuticAreas = new List<String>{ 'Pre-term', 'YCF 1-3' };
            w.createTask = true;
            w.taskTitle = x.taskTitle;
            w.taskDueDate = x.taskDueDate;
            RepCaptureController.SaveResult r = RepCaptureController.saveWalkIn(evId, w, 'email', null, 'Test browser');
            Assert.isNotNull(r.captureName);

            RepCaptureController.WalkIn w2 = new RepCaptureController.WalkIn();
            w2.firstName = 'Anon';
            w2.lastName = 'Walker';
            RepCaptureController.saveWalkIn(evId, w2, 'declined', null, 'Test browser');

            Boolean failed = false;
            try {
                RepCaptureController.saveWalkIn(evId, new RepCaptureController.WalkIn(), 'declined', null, 'Test browser');
            } catch (AuraHandledException e) {
                failed = true;
            }
            Assert.isTrue(failed, 'names are required');

            failed = false;
            try {
                RepCaptureController.saveWalkIn(evId, w2, 'email', null, 'Test browser');
            } catch (AuraHandledException e) {
                failed = true;
            }
            Assert.isTrue(failed, 'email method needs an email');

            List<RepCaptureController.MyCapture> mine = RepCaptureController.getMyCapturesToday();
            Assert.areEqual(2, mine.size());
            Assert.areEqual(31, RepCaptureController.getContext().therapeuticAreas.size(), 'therapeutic areas offered on the page');
        }
        Capture__c c = [SELECT Last_Name__c, Organisation__c, Interest__c, (SELECT Subject FROM Tasks) FROM Capture__c WHERE Last_Name__c = 'Bianchi'];
        Assert.areEqual('Gaslini', c.Organisation__c);
        Assert.areEqual('Product X', c.Interest__c);
        Assert.areEqual('Pre-term;YCF 1-3', [SELECT Therapeutic_Area__c FROM Capture__c WHERE Last_Name__c = 'Bianchi'].Therapeutic_Area__c, 'walk-in areas');
        Assert.areEqual(1, c.Tasks.size());
        Assert.areEqual('Call back Dr. Maria Bianchi', c.Tasks[0].Subject);
    }

    /** Kiosk entry of an HCP not identified yet (the HCP typed a personal email, so no auto-match). */
    private static Capture__c openKioskEntry(String first, String last, String email) {
        Capture__c c = ConsentTestFactory.capture(ev(), first, last, email, 'Paediatrics', 'Milan');
        c.Channel__c = CaptureConstants.CHANNEL_KIOSK;
        c.Matching_Status__c = CaptureConstants.MATCH_REVIEW;
        c.Processing_Stage__c = CaptureConstants.STAGE_TO_REVIEW;
        insert c;
        return c;
    }

    @IsTest
    static void kioskFirstRepLinksTheOpenEntry() {
        CaptureTriggerHandler.publishEnabled = false;
        Id evId = ev().Id;
        Capture__c entry = openKioskEntry('Elena', 'Greco', 'elena.greco@gmail.com');
        // a rep capture and an entry already resolved are never listed
        Capture__c repCapture = ConsentTestFactory.capture(ev(), 'Elena', 'Greco', null, 'Paediatrics', 'Milan');
        repCapture.Channel__c = CaptureConstants.CHANNEL_REP;
        Capture__c resolved = ConsentTestFactory.capture(ev(), 'Elena', 'Greco', 'other@gmail.com', 'Paediatrics', 'Milan');
        resolved.Matching_Status__c = CaptureConstants.MATCH_DISCARDED;
        insert new List<Capture__c>{ repCapture, resolved };
        User rep = ConsentTestFactory.user('HCP_Consent_Rep');
        Test.startTest();
        System.runAs(rep) {
            List<RepCaptureController.OpenEntry> found = RepCaptureController.searchOpenEntries('greco', evId);
            Assert.areEqual(1, found.size(), 'only the open kiosk / QR entry: ' + found);
            Assert.areEqual(entry.Id, found[0].id);
            Assert.areEqual('Kiosk', found[0].channelLabel);
            Assert.areEqual(1, RepCaptureController.searchOpenEntries('Elena Greco', evId).size(), 'every word must match');
            Assert.areEqual(0, RepCaptureController.searchOpenEntries('Mario Greco', evId).size());
            Assert.areEqual(1, RepCaptureController.searchOpenEntries('elena.greco@gmail', evId).size(), 'by email');
            Assert.areEqual(0, RepCaptureController.searchOpenEntries('g', evId).size(), 'term too short');
            Assert.areEqual(0, RepCaptureController.searchOpenEntries('greco', null).size(), 'no congress');

            String msg = RepCaptureController.linkOpenEntry(entry.Id, contactId('Greco'));
            Assert.isTrue(msg.contains('linked'), msg);
            Assert.areEqual(0, RepCaptureController.searchOpenEntries('greco', evId).size(), 'closed: no longer listed');

            Boolean twice = false;
            try {
                RepCaptureController.linkOpenEntry(entry.Id, contactId('Greco'));
            } catch (AuraHandledException e) {
                twice = true;
            }
            Assert.isTrue(twice, 'an entry already identified cannot be resolved again');
        }
        Test.stopTest();
        Capture__c after = [
            SELECT Matching_Status__c, Match_Rule__c, Matched_Contact__c, Reviewed_By__c, Consent__c
            FROM Capture__c
            WHERE Id = :entry.Id
        ];
        Assert.areEqual(CaptureConstants.MATCH_REVIEWED, after.Matching_Status__c);
        Assert.areEqual(OpenCaptureService.RULE_LINKED, after.Match_Rule__c);
        Assert.areEqual(contactId('Greco'), after.Matched_Contact__c);
        Assert.areEqual(rep.Id, after.Reviewed_By__c);
        Assert.isNotNull(after.Consent__c, 'consent given at the kiosk recorded on the HCP');
        Assert.areEqual(
            1,
            [SELECT COUNT() FROM Event_Attendee__c WHERE Event__c = :evId AND Contact__c = :contactId('Greco')],
            'attendee recorded once'
        );
    }

    @IsTest
    static void kioskFirstRepCreatesTheHcpFromTheEntry() {
        CaptureTriggerHandler.publishEnabled = false;
        Capture__c entry = openKioskEntry('Luca', 'Neri', 'luca.neri@gmail.com');
        User rep = ConsentTestFactory.user('HCP_Consent_Rep');
        Test.startTest();
        System.runAs(rep) {
            Assert.areEqual(0, RepCaptureController.searchHcps('Neri', ev().Id).size(), 'not in Salesforce yet');
            String msg = RepCaptureController.createHcpFromOpenEntry(entry.Id);
            Assert.isTrue(msg.contains('New HCP'), msg);
            Boolean badId = false;
            try {
                RepCaptureController.createHcpFromOpenEntry('not-an-id');
            } catch (AuraHandledException e) {
                badId = true;
            }
            Assert.isTrue(badId);
            Boolean unknownHcp = false;
            try {
                RepCaptureController.linkOpenEntry(entry.Id, null);
            } catch (AuraHandledException e) {
                unknownHcp = true;
            }
            Assert.isTrue(unknownHcp);
        }
        Test.stopTest();
        Capture__c after = [SELECT Matching_Status__c, Match_Rule__c, Matched_Contact__c FROM Capture__c WHERE Id = :entry.Id];
        Assert.areEqual(CaptureConstants.MATCH_REVIEWED_NEW, after.Matching_Status__c);
        Assert.areEqual(OpenCaptureService.RULE_NEW, after.Match_Rule__c);
        Assert.areEqual(after.Matched_Contact__c, contactId('Neri'), 'one new HCP, created from the entry');
    }

    @IsTest
    static void repFirstKioskLaterRanksTheCheckedInHcp() {
        CaptureTriggerHandler.publishEnabled = false;
        Event__c e = ev();
        Id greco = contactId('Greco');
        insert new Event_Attendee__c(
            Event__c = e.Id,
            Contact__c = greco,
            Attendee_Key__c = CaptureResolutionService.attendeeKey(e.Id, greco),
            Attendance_Status__c = CaptureConstants.ATTENDANCE_ATTENDED,
            Communications_Allowed__c = false
        );
        // later the HCP uses the kiosk with a personal email: no identical identifier, so review
        Capture__c later = ConsentTestFactory.capture(e, 'Elena', 'Greco', 'elena.g@gmail.com', 'Paediatrics', 'Milan');
        later.Channel__c = CaptureConstants.CHANNEL_KIOSK;
        insert later;
        Test.startTest();
        CaptureMatchingService.processCaptures(new Set<Id>{ later.Id });
        Test.stopTest();
        Capture_Candidate__c top = [
            SELECT Contact__c, Score_Explanation__c
            FROM Capture_Candidate__c
            WHERE Capture__c = :later.Id
            ORDER BY Rank__c ASC
            LIMIT 1
        ];
        Assert.areEqual(greco, top.Contact__c, 'the HCP the rep checked in is the top candidate');
        Assert.isTrue(top.Score_Explanation__c.contains('already checked in at this congress'), top.Score_Explanation__c);
        Assert.areEqual(1, [SELECT COUNT() FROM Event_Attendee__c WHERE Event__c = :e.Id AND Contact__c = :greco], 'no second attendee');
    }

    @IsTest
    static void accessIsChecked() {
        User nobody = ConsentTestFactory.user(null);
        System.runAs(nobody) {
            Boolean failed = false;
            try {
                RepCaptureController.getContext();
            } catch (AuraHandledException e) {
                failed = true;
            }
            Assert.isTrue(failed);
        }
    }
}
