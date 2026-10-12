@IsTest
private class CaptureMatchingServiceTest {
    @TestSetup
    static void setup() {
        ConsentTestFactory.settings();
        ConsentTestFactory.event();
        ConsentTestFactory.contact('Marco', 'Ferri', 'marco.ferri@policlinico-example.it', 'Paediatrics', 'Milan', 'MI-20418');
        ConsentTestFactory.contact('Giulia', 'Romano', 'g.romano@ospedale-example.it', 'Neonatology', 'Rome', 'RM-33102');
        ConsentTestFactory.contact('Maria', 'Bianchi', 'm.bianchi@gaslini-example.it', 'Paediatrics', 'Genoa', 'GE-11873');
        ConsentTestFactory.contact('Maria', 'Bianchi', 'maria.bianchi@sanraffaele-example.it', 'Gynaecology', 'Milan', 'MI-15530');
        ConsentTestFactory.contact('Marta', 'Bianchi', 'marta.bianchi@asl3-example.it', 'Paediatrics', 'Genoa', 'GE-12044');
    }

    private static Event__c ev() {
        return [SELECT Id FROM Event__c LIMIT 1];
    }

    private static Capture__c reload(Id id) {
        return [
            SELECT Matching_Status__c, Processing_Stage__c, Match_Rule__c, Matched_Contact__c, Matched_Contact__r.LastName,
                Consent__c, Candidate_Count__c, Suggestion__c, Suggestion_Confidence__c
            FROM Capture__c
            WHERE Id = :id
        ];
    }

    @IsTest
    static void rulesEmailRegNamesakeNew() {
        CaptureTriggerHandler.publishEnabled = false;
        Event__c e = ev();
        Capture__c byEmail = ConsentTestFactory.capture(e, 'Marco', 'Ferri', 'MARCO.FERRI@policlinico-example.it', 'Paediatrics', 'Milan');
        byEmail.Opt_In_Status__c = CaptureConstants.OPTIN_CONFIRMED;
        byEmail.Opt_In_Confirmed_At__c = System.now();
        Capture__c byReg = ConsentTestFactory.capture(e, 'Giulia', 'Romano', 'giulia.romano@gmail.com', 'Neonatology', 'Rome');
        byReg.Registration_Number__c = 'rm 33102';
        Capture__c namesake = ConsentTestFactory.capture(e, 'Maria', 'Bianchi', 'maria.bianchi@gmail.com', 'Paediatrics', 'Genoa');
        namesake.Organisation__c = 'Gaslini';
        Capture__c newHcp = ConsentTestFactory.capture(e, 'Silvia', 'Marchetti', 'silvia.marchetti@gmail.com', 'Paediatrics', 'Brescia');
        insert new List<Capture__c>{ byEmail, byReg, namesake, newHcp };

        Test.startTest();
        CaptureMatchingService.processCaptures(new Set<Id>{ byEmail.Id, byReg.Id, namesake.Id, newHcp.Id });
        Test.stopTest();

        Capture__c r1 = reload(byEmail.Id);
        Assert.areEqual(CaptureConstants.MATCH_AUTO, r1.Matching_Status__c);
        Assert.areEqual('Identical email', r1.Match_Rule__c);
        Assert.areEqual(CaptureConstants.STAGE_CONSENT_CREATED, r1.Processing_Stage__c);
        Consent__c k1 = [SELECT Status__c, Gigya_Status__c, Contact__c FROM Consent__c WHERE Id = :r1.Consent__c];
        Assert.areEqual(CaptureConstants.CONSENT_CONFIRMED, k1.Status__c);
        Assert.areEqual(CaptureConstants.GIGYA_QUEUED, k1.Gigya_Status__c);
        Assert.areEqual(CaptureConstants.HCP_OPTIN, [SELECT Consent_Status__c FROM Contact WHERE Id = :k1.Contact__c].Consent_Status__c);
        Assert.areEqual(1, [SELECT COUNT() FROM Event_Attendee__c WHERE Contact__c = :k1.Contact__c AND Communications_Allowed__c = TRUE]);

        Capture__c r2 = reload(byReg.Id);
        Assert.areEqual(CaptureConstants.MATCH_AUTO, r2.Matching_Status__c);
        Assert.areEqual('Identical registration number', r2.Match_Rule__c);
        Assert.areEqual('Romano', r2.Matched_Contact__r.LastName);

        Capture__c r3 = reload(namesake.Id);
        Assert.areEqual(CaptureConstants.MATCH_REVIEW, r3.Matching_Status__c);
        Assert.areEqual(CaptureConstants.STAGE_TO_REVIEW, r3.Processing_Stage__c);
        Assert.areEqual(3, r3.Candidate_Count__c);
        Assert.isNull(r3.Consent__c);
        Assert.isTrue(r3.Suggestion__c.startsWith('Recommended: Dr. Maria Bianchi - same surname, city and specialty'), r3.Suggestion__c);
        Assert.areEqual('High', r3.Suggestion_Confidence__c);
        Capture_Candidate__c top = [
            SELECT Score__c, Contact__r.MailingCity, Name_Match__c, Organisation_Match__c, Email_Match__c
            FROM Capture_Candidate__c
            WHERE Capture__c = :namesake.Id AND Recommended__c = TRUE
        ];
        Assert.areEqual(60, top.Score__c);
        Assert.areEqual('Genoa', top.Contact__r.MailingCity);
        Assert.areEqual(CaptureConstants.FLAG_EXACT, top.Name_Match__c);
        Assert.areEqual(CaptureConstants.FLAG_NONE, top.Email_Match__c);

        Capture__c r4 = reload(newHcp.Id);
        Assert.areEqual(CaptureConstants.MATCH_NEW, r4.Matching_Status__c);
        Contact created = [SELECT LastName, Consent_Status__c, Account.Name FROM Contact WHERE Id = :r4.Matched_Contact__c];
        Assert.areEqual('Marchetti', created.LastName);
        Assert.areEqual(CaptureConstants.HCP_PENDING, created.Consent_Status__c);
        Assert.areEqual(CaptureConstants.UNKNOWN_ORGANISATION, created.Account.Name);
    }

    @IsTest
    static void repSelectedExistingAndDeclined() {
        CaptureTriggerHandler.publishEnabled = false;
        Event__c e = ev();
        Contact ferri = [SELECT Id FROM Contact WHERE LastName = 'Ferri'];
        Contact romano = [SELECT Id FROM Contact WHERE LastName = 'Romano'];
        Consent__c existing = ConsentTestFactory.confirmedConsent(ferri.Id);

        Capture__c reuse = ConsentTestFactory.capture(e, 'Marco', 'Ferri', null, 'Paediatrics', 'Milan');
        reuse.Channel__c = CaptureConstants.CHANNEL_REP;
        reuse.HCP_Selected_By_Rep__c = true;
        reuse.Matched_Contact__c = ferri.Id;
        reuse.Consent_Method__c = CaptureConstants.METHOD_EXISTING;
        reuse.Opt_In_Status__c = CaptureConstants.OPTIN_CONFIRMED;

        Capture__c declined = ConsentTestFactory.capture(e, 'Giulia', 'Romano', null, 'Neonatology', 'Rome');
        declined.Channel__c = CaptureConstants.CHANNEL_REP;
        declined.HCP_Selected_By_Rep__c = true;
        declined.Matched_Contact__c = romano.Id;
        declined.Consent_Given__c = false;
        declined.Consent_Method__c = CaptureConstants.METHOD_DECLINED;
        declined.Opt_In_Status__c = CaptureConstants.OPTIN_DECLINED;
        insert new List<Capture__c>{ reuse, declined };

        Test.startTest();
        CaptureMatchingService.processCaptures(new Set<Id>{ reuse.Id, declined.Id });
        Test.stopTest();

        Capture__c r1 = reload(reuse.Id);
        Assert.areEqual('HCP selected by rep', r1.Match_Rule__c);
        Assert.areEqual(existing.Id, r1.Consent__c, 'existing consent is reused');
        Assert.areEqual(CaptureConstants.STAGE_SENT, r1.Processing_Stage__c);
        Assert.areEqual(1, [SELECT COUNT() FROM Consent__c WHERE Contact__c = :ferri.Id], 'no new consent record');

        Capture__c r2 = reload(declined.Id);
        Assert.areEqual(CaptureConstants.STAGE_NO_CONSENT, r2.Processing_Stage__c);
        Assert.isNull(r2.Consent__c);
        Assert.areEqual(0, [SELECT COUNT() FROM Consent__c WHERE Contact__c = :romano.Id]);
        Assert.areEqual(1, [SELECT COUNT() FROM Event_Attendee__c WHERE Contact__c = :romano.Id AND Communications_Allowed__c = FALSE]);
    }

    @IsTest
    static void platformEventTriggersMatching() {
        Event__c e = ev();
        Test.startTest();
        insert ConsentTestFactory.capture(e, 'Marco', 'Ferri', 'marco.ferri@policlinico-example.it', 'Paediatrics', 'Milan');
        Test.stopTest();
        Capture__c c = [SELECT Matching_Status__c FROM Capture__c LIMIT 1];
        Assert.areEqual(CaptureConstants.MATCH_AUTO, c.Matching_Status__c);
    }

    @IsTest
    static void signatureIsLinkedToConsent() {
        CaptureTriggerHandler.publishEnabled = false;
        Contact romano = [SELECT Id FROM Contact WHERE LastName = 'Romano'];
        Capture__c c = ConsentTestFactory.capture(ev(), 'Giulia', 'Romano', null, 'Neonatology', 'Rome');
        c.HCP_Selected_By_Rep__c = true;
        c.Matched_Contact__c = romano.Id;
        c.Consent_Method__c = CaptureConstants.METHOD_SIGNATURE;
        c.Opt_In_Status__c = CaptureConstants.OPTIN_CONFIRMED;
        c.Signature_Captured__c = true;
        insert c;
        ConsentService.saveSignature(c.Id, 'CAP-TEST', ConsentTestFactory.signature());
        CaptureMatchingService.processCaptures(new Set<Id>{ c.Id });
        Capture__c r = reload(c.Id);
        Consent__c k = [SELECT Opt_In_Method__c, Signature_Captured__c FROM Consent__c WHERE Id = :r.Consent__c];
        Assert.areEqual(CaptureConstants.METHOD_SIGNATURE, k.Opt_In_Method__c);
        Assert.isTrue(k.Signature_Captured__c);
        Assert.areEqual(1, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :r.Consent__c]);
    }

    @IsTest
    static void helpers() {
        Assert.areEqual('nicolo', CaptureMatchingService.normalize('Nicolò'));
        Assert.areEqual('', CaptureMatchingService.normalize(null));
        Assert.areEqual('a.b@c.it', CaptureMatchingService.normalize(' A.B@C.it '));
        // already processed captures are ignored
        CaptureTriggerHandler.publishEnabled = false;
        Capture__c c = ConsentTestFactory.capture(ev(), 'X', 'Nobody', null, null, null);
        c.Matching_Status__c = CaptureConstants.MATCH_DISCARDED;
        insert c;
        CaptureMatchingService.processCaptures(new Set<Id>{ c.Id, null });
        Assert.areEqual(CaptureConstants.MATCH_DISCARDED, reload(c.Id).Matching_Status__c);
    }
}
