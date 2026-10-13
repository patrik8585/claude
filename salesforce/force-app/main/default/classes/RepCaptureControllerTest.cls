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
            RepCaptureController.SaveResult existing = RepCaptureController.addKnownHcp(evId, contactId('Ferri'), null, null, 'Test browser');
            Assert.isTrue(existing.message.contains('on file'));

            RepCaptureController.SaveResult signed = RepCaptureController.addKnownHcp(evId, contactId('Greco'), 'sign', ConsentTestFactory.signature(), 'Test browser');
            Assert.isTrue(signed.message.startsWith('Signed'));

            RepCaptureController.SaveResult mailed = RepCaptureController.addKnownHcp(evId, contactId('Conti'), 'declined', null, 'Test browser');
            Assert.isTrue(mailed.message.contains('declined'));

            Boolean blocked = false;
            try {
                RepCaptureController.addKnownHcp(evId, contactId('Conti'), 'email', null, 'Test browser');
            } catch (AuraHandledException e) {
                blocked = true;
            }
            Assert.isTrue(blocked, 'opted-out HCPs cannot get an email link');

            Boolean noSignature = false;
            try {
                RepCaptureController.addKnownHcp(evId, contactId('Greco'), 'sign', null, 'Test browser');
            } catch (AuraHandledException e) {
                noSignature = true;
            }
            Assert.isTrue(noSignature);

            Assert.areEqual(1, RepCaptureController.searchHcps('Ferri', evId).size());
            Assert.isTrue(RepCaptureController.searchHcps('Ferri', evId)[0].alreadyAdded);

            List<RepCaptureController.MyCapture> mine = RepCaptureController.getMyCapturesToday();
            Assert.areEqual(3, mine.size());
        }
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
            RepCaptureController.SaveResult r = RepCaptureController.addKnownHcp(evId, contactId('Greco'), 'email', null, 'Test browser');
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
        }
        Capture__c c = [SELECT Last_Name__c, Organisation__c, Interest__c, (SELECT Subject FROM Tasks) FROM Capture__c WHERE Last_Name__c = 'Bianchi'];
        Assert.areEqual('Gaslini', c.Organisation__c);
        Assert.areEqual('Product X', c.Interest__c);
        Assert.areEqual(1, c.Tasks.size());
        Assert.areEqual('Call back Dr. Maria Bianchi', c.Tasks[0].Subject);
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
