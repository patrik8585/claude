@IsTest
private class HcpMatchEngineTest {
    @TestSetup
    static void setup() {
        ConsentTestFactory.settings();
        ConsentTestFactory.event();
        System.runAs(ConsentTestFactory.user('HCP_Consent_Admin')) {
            Account gaslini = ConsentTestFactory.hospital('Gaslini Institute', 'Genoa', 'gaslini-example.it', 'Gaslini; Istituto Gaslini');
            Account niguarda = ConsentTestFactory.hospital('Ospedale Niguarda', 'Milan', 'niguarda-example.it', 'Niguarda');
            Account gPaed = ConsentTestFactory.department(gaslini, 'Paediatrics');
            Account gNeo = ConsentTestFactory.department(gaslini, 'Neonatology');
            Account nPaed = ConsentTestFactory.department(niguarda, 'Paediatrics');
            ConsentTestFactory.contactAt('Maria', 'Bianchi', 'm.bianchi@gaslini-example.it', 'Paediatrics', 'Genoa', 'GE-11873', gPaed.Id);
            ConsentTestFactory.contactAt('Maria', 'Bianchi', 'maria.bianchi@niguarda-example.it', 'Paediatrics', 'Milan', 'MI-15530', nPaed.Id);
            ConsentTestFactory.contactAt('Nicolò', 'Ferraresi', 'n.ferraresi@gaslini-example.it', 'Neonatology', 'Genoa', 'GE-020418', gNeo.Id);
            ConsentTestFactory.contactAt('Lorenzo', 'Pellegrini', 'l.pellegrini@niguarda-example.it', 'Paediatrics', 'Milan', null, nPaed.Id);
            // the same person entered twice (same email)
            ConsentTestFactory.contactAt('Giorgio', 'Valenti', 'giorgio.valenti@gmail.com', 'Paediatrics', 'Milan', 'MI-30001', nPaed.Id);
            ConsentTestFactory.contactAt('Giorgio', 'Valenti', 'giorgio.valenti@gmail.com', 'Paediatrics', 'Milan', null, nPaed.Id);
        }
    }

    private static Event__c ev() {
        return [SELECT Id FROM Event__c LIMIT 1];
    }

    private static Capture__c reload(Id id) {
        return [
            SELECT Matching_Status__c, Match_Rule__c, Matched_Contact__c, Matched_Contact__r.Email, Hospital__c, Hospital__r.Name, Department__c,
                Candidate_Count__c, Suggestion__c, Suggestion_Confidence__c
            FROM Capture__c
            WHERE Id = :id
        ];
    }

    private static Capture__c run(Capture__c c) {
        CaptureTriggerHandler.publishEnabled = false;
        insert c;
        CaptureMatchingService.processCaptures(new Set<Id>{ c.Id });
        return reload(c.Id);
    }

    @IsTest
    static void normalisationAndSimilarity() {
        Assert.areEqual('nicolo', HcpMatchEngine.normalizeName('Nicolò'));
        Assert.areEqual('damico', HcpMatchEngine.normalizeName('D\'Amico'));
        Assert.areEqual('deluca', HcpMatchEngine.normalizeName('De Luca'));
        Assert.areEqual('MI20418', HcpMatchEngine.registrationKey('mi 020418'));
        Assert.areEqual('MI20418', HcpMatchEngine.registrationKey('MI/20418'));
        Assert.areEqual('', HcpMatchEngine.registrationKey(null));
        Assert.areEqual('gaslini-example.it', HcpMatchEngine.emailDomain('A@Gaslini-Example.it'));
        MatchingConfig cfg = MatchingConfig.get();
        Assert.isTrue(HcpMatchEngine.close('pellegrini', 'pelegrini', cfg), 'one letter missing');
        Assert.isTrue(HcpMatchEngine.close('pellegrini', 'pellegirni', cfg), 'two letters swapped = distance 2 on a long name');
        Assert.isFalse(HcpMatchEngine.close('rossi', 'russo', cfg), 'short names allow one edit only');
        Assert.isTrue(cfg.isPersonalDomain('gmail.com'));
        Assert.isFalse(cfg.isPersonalDomain('gaslini-example.it'));

        HcpMatchEngine.Profile a = new HcpMatchEngine.Profile();
        a.firstName = 'Pellegrini';
        a.lastName = 'Lorenzo';
        HcpMatchEngine.Profile b = new HcpMatchEngine.Profile();
        b.firstName = 'Lorenzo';
        b.lastName = 'Pellegrini';
        HcpMatchEngine.Comparison swapped = HcpMatchEngine.compare(a, b);
        Assert.areEqual(HcpMatchEngine.NAME_SWAPPED, swapped.nameKind);
        Assert.areEqual(CaptureConstants.FLAG_PARTIAL, swapped.nameFlag);
        a.firstName = 'L';
        a.lastName = 'Pellegrini';
        a.email = null;
        HcpMatchEngine.Profile a2 = new HcpMatchEngine.Profile();
        a2.firstName = 'L';
        a2.lastName = 'Pellegrini';
        Assert.areEqual(HcpMatchEngine.NAME_FUZZY, HcpMatchEngine.compare(a2, b).nameKind, 'initial matches the first name');
    }

    @IsTest
    static void departmentRanksTheRightNamesake() {
        Capture__c c = ConsentTestFactory.capture(ev(), 'Maria', 'Bianchi', 'mariabianchi73@gmail.com', 'Paediatrics', 'Genoa');
        c.Organisation__c = 'Istituto Gaslini';
        Capture__c r = run(c);
        Assert.areEqual(CaptureConstants.MATCH_REVIEW, r.Matching_Status__c);
        Assert.areEqual('Gaslini Institute', r.Hospital__r.Name, 'hospital resolved from the alias');
        Assert.areEqual(2, r.Candidate_Count__c);
        Capture_Candidate__c top = [
            SELECT Contact__r.Email, Organisation_Match__c, Score_Explanation__c
            FROM Capture_Candidate__c
            WHERE Capture__c = :c.Id AND Recommended__c = TRUE
        ];
        Assert.areEqual('m.bianchi@gaslini-example.it', top.Contact__r.Email);
        Assert.areEqual(CaptureConstants.FLAG_PARTIAL, top.Organisation_Match__c, 'same hospital (the capture has no department)');
        Assert.isTrue(top.Score_Explanation__c.contains('same hospital (Gaslini Institute)'), top.Score_Explanation__c);
        Assert.isTrue(r.Suggestion__c.contains('hospital inferred from organisation'), r.Suggestion__c);
    }

    @IsTest
    static void typoAccentAndSwappedGoToReview() {
        Event__c e = ev();
        // typo in the surname, personal email, hospital known only from the email domain? no: personal -> by name prefix
        Capture__c typo = ConsentTestFactory.capture(e, 'Lorenzo', 'Pelegrini', 'lorenzo.p@gmail.com', 'Paediatrics', 'Milan');
        Capture__c accent = ConsentTestFactory.capture(e, 'Nicolo', 'Ferraresi', null, 'Neonatology', 'Genoa');
        Capture__c swapped = ConsentTestFactory.capture(e, 'Pellegrini', 'Lorenzo', null, 'Paediatrics', 'Milan');
        CaptureTriggerHandler.publishEnabled = false;
        insert new List<Capture__c>{ typo, accent, swapped };
        CaptureMatchingService.processCaptures(new Set<Id>{ typo.Id, accent.Id, swapped.Id });

        for (Capture__c c : new List<Capture__c>{ reload(typo.Id), reload(accent.Id), reload(swapped.Id) }) {
            Assert.areEqual(CaptureConstants.MATCH_REVIEW, c.Matching_Status__c, 'fuzzy evidence never auto-matches: ' + c.Match_Rule__c);
        }
        Assert.areEqual(
            'Exact',
            [SELECT Name_Match__c FROM Capture_Candidate__c WHERE Capture__c = :accent.Id AND Recommended__c = TRUE].Name_Match__c,
            'Nicolo = Nicolò'
        );
        Assert.isTrue(
            [SELECT Score_Explanation__c FROM Capture_Candidate__c WHERE Capture__c = :swapped.Id AND Recommended__c = TRUE]
                .Score_Explanation__c.contains('swapped')
        );
        Assert.isTrue(
            [SELECT Score_Explanation__c FROM Capture_Candidate__c WHERE Capture__c = :typo.Id AND Recommended__c = TRUE]
                .Score_Explanation__c.contains('name similar')
        );
    }

    @IsTest
    static void conflictsGoToReview() {
        Event__c e = ev();
        Capture__c sharedEmail = ConsentTestFactory.capture(e, 'Giorgio', 'Valenti', 'giorgio.valenti@gmail.com', 'Paediatrics', 'Milan');
        Capture__c regDiffers = ConsentTestFactory.capture(e, 'Maria', 'Bianchi', 'm.bianchi@gaslini-example.it', 'Paediatrics', 'Genoa');
        regDiffers.Registration_Number__c = 'MI-15530';
        Capture__c leadingZero = ConsentTestFactory.capture(e, 'Nicolò', 'Ferraresi', null, 'Neonatology', 'Genoa');
        leadingZero.Registration_Number__c = 'ge 20418';
        CaptureTriggerHandler.publishEnabled = false;
        insert new List<Capture__c>{ sharedEmail, regDiffers, leadingZero };
        CaptureMatchingService.processCaptures(new Set<Id>{ sharedEmail.Id, regDiffers.Id, leadingZero.Id });

        Capture__c r1 = reload(sharedEmail.Id);
        Assert.areEqual(CaptureConstants.MATCH_REVIEW, r1.Matching_Status__c);
        Assert.isTrue(r1.Match_Rule__c.contains('email shared by 2 HCPs'), r1.Match_Rule__c);

        Capture__c r2 = reload(regDiffers.Id);
        Assert.areEqual(CaptureConstants.MATCH_REVIEW, r2.Matching_Status__c);
        Assert.isTrue(r2.Match_Rule__c.contains('point to different HCPs') || r2.Match_Rule__c.contains('registration number differs'), r2.Match_Rule__c);
        Assert.isTrue(r2.Suggestion__c.contains('Attention:'), r2.Suggestion__c);

        Capture__c r3 = reload(leadingZero.Id);
        Assert.areEqual(CaptureConstants.MATCH_AUTO, r3.Matching_Status__c, 'GE 20418 = GE-020418');
        Assert.areEqual('Identical registration number', r3.Match_Rule__c);
    }

    @IsTest
    static void parametersComeFromCustomMetadata() {
        MatchingConfig.overrideRecord = (Matching_Setting__mdt) JSON.deserialize(
            '{"Auto_Match_Email__c": false, "Auto_Match_Registration__c": true, "Review_On_Conflict__c": true, "Weight_Name_Exact__c": 40}',
            Matching_Setting__mdt.class
        );
        MatchingConfig.reset();
        Assert.areEqual(40, MatchingConfig.get().wNameExact);
        Assert.areEqual(20, MatchingConfig.get().wEmail, 'empty field -> built-in default');
        Capture__c r = run(ConsentTestFactory.capture(ev(), 'Maria', 'Bianchi', 'm.bianchi@gaslini-example.it', 'Paediatrics', 'Genoa'));
        Assert.areEqual(CaptureConstants.MATCH_REVIEW, r.Matching_Status__c, 'email auto-match switched off');
        Assert.isNotNull(Matching_Setting__mdt.getInstance('Default'), 'the Default record is deployed with the project');
    }

    @IsTest
    static void newHcpGoesToTheDepartmentOfTheEmailHospital() {
        Capture__c r = run(ConsentTestFactory.capture(ev(), 'Beatrice', 'Sommaruga', 'b.sommaruga@gaslini-example.it', 'Neonatology', null));
        Assert.areEqual(CaptureConstants.MATCH_NEW, r.Matching_Status__c);
        Contact ct = [SELECT Account.Name, Account.Department_Type__c, MailingCity FROM Contact WHERE Id = :r.Matched_Contact__c];
        Assert.areEqual('Neonatology - Gaslini Institute', ct.Account.Name);
        Assert.areEqual('Genoa', ct.MailingCity, 'city taken from the hospital');
        HCP_Affiliation__c a = [SELECT Primary__c, Hospital_Name__c, Department_Name__c FROM HCP_Affiliation__c WHERE Contact__c = :r.Matched_Contact__c];
        Assert.isTrue(a.Primary__c);
        Assert.areEqual('Gaslini Institute', a.Hospital_Name__c);
        Assert.areEqual('Neonatology', a.Department_Name__c);
        Assert.isNotNull(r.Department__c);
    }

    @IsTest
    static void onePrimaryAffiliationSetsTheAccount() {
        Contact c = [SELECT Id, AccountId FROM Contact WHERE Email = 'l.pellegrini@niguarda-example.it'];
        Account gNeo = [SELECT Id FROM Account WHERE Name = 'Neonatology - Gaslini Institute'];
        Test.startTest();
        insert new HCP_Affiliation__c(Contact__c = c.Id, HCO__c = gNeo.Id, Primary__c = true);
        Test.stopTest();
        Assert.areEqual(gNeo.Id, [SELECT AccountId FROM Contact WHERE Id = :c.Id].AccountId);
        Assert.areEqual(1, [SELECT COUNT() FROM HCP_Affiliation__c WHERE Contact__c = :c.Id AND Primary__c = TRUE]);
        Assert.areEqual(2, [SELECT COUNT() FROM HCP_Affiliation__c WHERE Contact__c = :c.Id]);
        Boolean duplicateBlocked = false;
        try {
            insert new HCP_Affiliation__c(Contact__c = c.Id, HCO__c = gNeo.Id);
        } catch (DmlException e) {
            duplicateBlocked = true;
        }
        Assert.isTrue(duplicateBlocked, 'unique affiliation key');
        delete [SELECT Id FROM HCP_Affiliation__c WHERE Contact__c = :c.Id AND HCO__c = :gNeo.Id];
        HCP_Affiliation__c left = [SELECT Primary__c, HCO__c FROM HCP_Affiliation__c WHERE Contact__c = :c.Id];
        Assert.isTrue(left.Primary__c, 'the remaining affiliation is promoted');
        Assert.areEqual(left.HCO__c, [SELECT AccountId FROM Contact WHERE Id = :c.Id].AccountId);
    }

    @IsTest
    static void repPicksHospitalAndDepartment() {
        Event__c e = ev();
        User rep = ConsentTestFactory.user('HCP_Consent_Rep');
        System.runAs(rep) {
            List<RepCaptureController.HcoOption> hs = RepCaptureController.searchHospitals('gasl');
            Assert.areEqual(1, hs.size());
            List<RepCaptureController.HcoOption> ds = RepCaptureController.getDepartments(hs[0].id);
            Assert.areEqual(2, ds.size());
            RepCaptureController.WalkIn w = new RepCaptureController.WalkIn();
            w.firstName = 'Ada';
            w.lastName = 'Zanetti';
            w.hospitalId = hs[0].id;
            w.departmentId = ds[0].id;
            CaptureTriggerHandler.publishEnabled = false;
            RepCaptureController.saveWalkIn(e.Id, w, 'declined', null, 'test');
            List<RepCaptureController.HcpResult> found = RepCaptureController.searchHcps('Ferraresi', e.Id);
            Assert.areEqual(1, found.size());
            Assert.areEqual('Gaslini Institute', found[0].hospital);
            Assert.areEqual('Neonatology', found[0].department);
            Assert.isTrue(found[0].affiliations.contains('(primary)'), found[0].affiliations);
        }
        Capture__c c = [SELECT Hospital__r.Name, Department__c, Organisation__c FROM Capture__c WHERE Last_Name__c = 'Zanetti'];
        Assert.areEqual('Gaslini Institute', c.Hospital__r.Name);
        Assert.areEqual('Gaslini Institute', c.Organisation__c);
        Assert.isNotNull(c.Department__c);
    }

    @IsTest
    static void stewardBulkActions() {
        Event__c e = ev();
        List<Capture__c> caps = new List<Capture__c>();
        for (Integer i = 0; i < 3; i++) {
            Capture__c c = ConsentTestFactory.capture(e, 'Maria', 'Bianchi', 'mb' + i + '@gmail.com', 'Paediatrics', 'Genoa');
            c.Opt_In_Status__c = CaptureConstants.OPTIN_CONFIRMED;
            caps.add(c);
        }
        CaptureTriggerHandler.publishEnabled = false;
        insert caps;
        CaptureMatchingService.processCaptures(new Map<Id, Capture__c>(caps).keySet());
        User steward = ConsentTestFactory.user('HCP_Consent_Data_Steward');
        System.runAs(steward) {
            CaptureReviewController.BulkResult r1 = CaptureReviewController.bulkResolve(new List<Id>{ caps[0].Id }, 'recommended');
            Assert.areEqual(1, r1.processed, r1.message);
            CaptureReviewController.BulkResult r2 = CaptureReviewController.bulkResolve(new List<Id>{ caps[1].Id, caps[0].Id }, 'new');
            Assert.areEqual(1, r2.processed, r2.message);
            Assert.areEqual(1, r2.skipped, 'already resolved');
            CaptureReviewController.BulkResult r3 = CaptureReviewController.bulkResolve(new List<Id>{ caps[2].Id }, 'discard');
            Assert.areEqual(1, r3.processed, r3.message);
            CaptureReviewController.ReviewData d = CaptureReviewController.getReviewData(caps[0].Id);
            Assert.isNotNull(d.capture);
        }
        Assert.areEqual(CaptureConstants.MATCH_REVIEWED, [SELECT Matching_Status__c FROM Capture__c WHERE Id = :caps[0].Id].Matching_Status__c);
        Assert.areEqual(CaptureConstants.MATCH_REVIEWED_NEW, [SELECT Matching_Status__c FROM Capture__c WHERE Id = :caps[1].Id].Matching_Status__c);
        Assert.areEqual(CaptureConstants.MATCH_DISCARDED, [SELECT Matching_Status__c FROM Capture__c WHERE Id = :caps[2].Id].Matching_Status__c);
    }
}
