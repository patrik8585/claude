@IsTest
private class MatchingWorkbenchTest {
    private static User admin() {
        return ConsentTestFactory.user('HCP_Consent_Admin');
    }

    @IsTest
    static void volumeDataAndAccuracy() {
        ConsentTestFactory.settings();
        System.runAs(admin()) {
            VolumeTestData.small = true;
            VolumeTestData.Plan plan = new VolumeTestData.Plan();
            Assert.areEqual(6, plan.hospitals.size());
            Assert.areEqual(14, plan.captures.size(), 'one capture per test case');
            List<String> steps = new List<String>{ 'CLEAN_CAPTURES', 'CLEAN_CONTACTS', 'CLEAN_ACCOUNTS', 'HOSPITALS' };
            for (Integer i = 0; i * VolumeTestData.HCP_CHUNK < plan.hcps.size(); i++) {
                steps.add('HCPS:' + i);
            }
            steps.add('DUPLICATES');
            VolumeTestData job = new VolumeTestData(steps);
            Assert.areEqual(steps.size(), ((List<String>) job.start(null)).size());
            for (String s : steps) {
                job.execute(null, new List<String>{ s });
            }
            Assert.areEqual(plan.hcps.size() + plan.duplicates.size(), [SELECT COUNT() FROM Contact WHERE Test_Data_Set__c = :VolumeTestData.DATA_SET]);
            Assert.areEqual(5, [SELECT COUNT() FROM Contact WHERE Test_Duplicate_Of__c != NULL]);
            Assert.isTrue([SELECT COUNT() FROM HCP_Affiliation__c] >= plan.hcps.size());
            // matching is called directly (the platform-event path is covered by CaptureMatchingServiceTest)
            CaptureTriggerHandler.publishEnabled = false;
            job.execute(null, new List<String>{ 'CAPTURES' });
            Set<Id> captureIds = new Map<Id, Capture__c>([SELECT Id FROM Capture__c WHERE Test_Data_Set__c = :VolumeTestData.CAPTURE_SET]).keySet();
            Assert.areEqual(14, captureIds.size());
            Test.startTest();
            CaptureMatchingService.processCaptures(captureIds);
            Test.stopTest();
            job.finish(null);

            List<String> states = new List<String>();
            for (Capture__c c : [SELECT Test_Case__c, Matching_Status__c, Processing_Error__c FROM Capture__c WHERE Id IN :captureIds]) {
                states.add(c.Test_Case__c + ' = ' + c.Matching_Status__c + (c.Processing_Error__c == null ? '' : ' / ' + c.Processing_Error__c.left(300)));
            }
            String diagnostics = String.join(states, ' | ');
            MatchingAccuracyController.Metrics m = MatchingAccuracyController.getMetrics();
            Assert.areEqual(14, m.total, diagnostics);
            Assert.areEqual(0, m.pending, 'all test captures were matched: ' + diagnostics);
            Assert.areEqual(14, m.byCase.size());
            Assert.areEqual(6, m.hospitals);
            for (MatchingAccuracyController.CaseRow r : m.byCase) {
                if (r.testCase == 'Exact institutional email' || r.testCase == 'Really new HCP' || r.testCase == 'Email shared by duplicates') {
                    Assert.areEqual(1, r.asExpected, r.testCase + ' / ' + diagnostics);
                }
            }
            Assert.isTrue(m.autoCount > 0 && m.autoPrecision == 100, 'auto-matches are always right: ' + String.valueOf(m.problems) + ' / ' + diagnostics);

            // re-run only the captures (as after changing Matching_Setting__mdt), then clean everything
            VolumeTestData.runStep('CLEAN_CAPTURES');
            Assert.areEqual(0, [SELECT COUNT() FROM Capture__c WHERE Test_Data_Set__c = :VolumeTestData.CAPTURE_SET]);
            VolumeTestData.runStep('CLEAN_CONTACTS');
            VolumeTestData.runStep('CLEAN_ACCOUNTS');
            Assert.areEqual(0, [SELECT COUNT() FROM Contact WHERE Test_Data_Set__c != NULL]);
            Assert.areEqual(0, [SELECT COUNT() FROM Account WHERE Test_Data_Set__c != NULL]);
            Boolean unknown = false;
            try {
                MatchingAccuracyController.runGenerator('nonsense');
            } catch (AuraHandledException e) {
                unknown = true;
            }
            Assert.isTrue(unknown, 'unknown generator action');
        }
        Assert.areEqual('Typo', VolumeTestData.typo('Typpo'));
        Assert.areEqual('Csota', VolumeTestData.typo('Costa'));
        Assert.isTrue(HcpMatchEngine.isTransposition('costa', 'csota'));
        Assert.areEqual('Nicolo', VolumeTestData.stripAccents('Nicolò'));
        Assert.areEqual(VolumeTestData.OUT_REVIEW, MatchingAccuracyController.actualOutcome(CaptureConstants.MATCH_REVIEWED_NEW));
    }

    @IsTest
    static void duplicateScanMergeAndEvidence() {
        ConsentTestFactory.settings();
        Event__c ev = ConsentTestFactory.event();
        Contact a;
        Contact b;
        Contact c;
        Contact d;
        Account hosp;
        Account dept;
        System.runAs(admin()) {
            hosp = ConsentTestFactory.hospital('Gaslini Institute', 'Genoa', 'gaslini-example.it', 'Gaslini');
            dept = ConsentTestFactory.department(hosp, 'Paediatrics');
            a = ConsentTestFactory.contactAt('Maria', 'Bianchi', 'm.bianchi@gaslini-example.it', 'Paediatrics', 'Genoa', 'GE-11873', dept.Id);
            b = ConsentTestFactory.contactAt('Maria', 'Bianchi', 'mariabianchi@gmail.com', 'Paediatrics', 'Genoa', 'GE 11873', dept.Id);
            c = ConsentTestFactory.contactAt('Mario', 'Rossetti', null, 'Paediatrics', 'Genoa', null, dept.Id);
            d = ConsentTestFactory.contactAt('Rossetti', 'Mario', null, 'Paediatrics', 'Genoa', null, dept.Id);
            ConsentTestFactory.contactAt('Luca', 'Verdi', 'l.verdi@gaslini-example.it', 'Neonatology', 'Genoa', 'GE-55555', hosp.Id);
        }
        // consent recorded for B (evidence hash includes B's Id), attendances of both at the same event
        Consent__c k = new Consent__c(
            Contact__c = b.Id,
            Consent_Type__c = CaptureConstants.CONSENT_TYPE_EMAIL,
            Status__c = CaptureConstants.CONSENT_CONFIRMED,
            Channel__c = CaptureConstants.CHANNEL_REP,
            Captured_At__c = System.now().addDays(-3),
            Confirmed_At__c = System.now().addDays(-3),
            Consent_Text_Version__c = 'v3.2',
            Opt_In_Method__c = CaptureConstants.METHOD_SIGNATURE,
            Gigya_Status__c = CaptureConstants.GIGYA_SENT
        );
        k.Evidence_Hash__c = ConsentService.evidenceHash(k);
        insert k;
        insert new List<Event_Attendee__c>{
            new Event_Attendee__c(Event__c = ev.Id, Contact__c = a.Id, Attendee_Key__c = 'A1', Communications_Allowed__c = true),
            new Event_Attendee__c(Event__c = ev.Id, Contact__c = b.Id, Attendee_Key__c = 'B1', Communications_Allowed__c = false)
        };

        DuplicateScanJob job = new DuplicateScanJob();
        Assert.areEqual(27, ((List<String>) job.start(null)).size());
        job.execute(null, new List<String>{ 'b' });
        Assert.isTrue(DuplicateScanJob.scanBlock('r') >= 1, 'swapped names');
        job.execute(null, new List<String>{ DuplicateScanJob.IDENTIFIERS });
        job.finish(null);
        HCP_Duplicate_Pair__c ab = [SELECT Id, Score__c, Reg_Number_Match__c FROM HCP_Duplicate_Pair__c WHERE Pair_Key__c = :DuplicateScanJob.pairKey(a.Id, b.Id)];
        Assert.areEqual(CaptureConstants.FLAG_EXACT, ab.Reg_Number_Match__c, 'GE-11873 = GE 11873');
        HCP_Duplicate_Pair__c cd = [SELECT Id FROM HCP_Duplicate_Pair__c WHERE Pair_Key__c = :DuplicateScanJob.pairKey(c.Id, d.Id)];
        Assert.areEqual(0, [SELECT COUNT() FROM HCP_Duplicate_Pair__c WHERE Contact_A__r.LastName = 'Verdi' OR Contact_B__r.LastName = 'Verdi']);

        User steward = ConsentTestFactory.user('HCP_Consent_Data_Steward');
        String mergeId;
        System.runAs(steward) {
            Assert.isTrue(MatchingWorkbenchController.getHcoOptions().size() >= 2);
            Assert.areEqual(2, MatchingWorkbenchController.getPairs('Open', hosp.Id, null, 0).size());
            Assert.areEqual(2, MatchingWorkbenchController.getPairs('Open', null, dept.Id, 50).size());
            MatchingWorkbenchController.PairDetail detail = MatchingWorkbenchController.getPairDetail(ab.Id);
            Assert.areEqual(HcpMergeService.MERGE_FIELDS.size(), detail.fields.size());
            Assert.areEqual(b.Id, detail.suggestedMaster, 'B has the consent and the attendance');
            Assert.isFalse(detail.explanation.isEmpty());

            mergeId = MatchingWorkbenchController.mergePair(ab.Id, a.Id, new Map<String, String>{ 'Email' => 'master', 'Registration_Number__c' => 'master' });
            Assert.isNotNull(mergeId);

            MatchingWorkbenchController.markNotDuplicate(cd.Id, 'Two different people');
            Boolean failed = false;
            try {
                MatchingWorkbenchController.markNotDuplicate(cd.Id, null);
            } catch (AuraHandledException e) {
                failed = true;
            }
            Assert.isTrue(failed, 'already decided');
            Assert.areEqual(1, MatchingWorkbenchController.getMerges().size());
            Assert.isNotNull(MatchingWorkbenchController.getReviewQueue(null, null));
            Assert.isNull(MatchingWorkbenchController.getJobStatus(null));
        }

        Assert.areEqual(0, [SELECT COUNT() FROM Contact WHERE Id = :b.Id], 'B merged away');
        Consent__c moved = [SELECT Contact__c FROM Consent__c WHERE Id = :k.Id];
        Assert.areEqual(a.Id, moved.Contact__c, 'consent kept on the survivor');
        Assert.areEqual(CaptureConstants.HCP_OPTIN, [SELECT Consent_Status__c FROM Contact WHERE Id = :a.Id].Consent_Status__c);
        List<Event_Attendee__c> att = [SELECT Communications_Allowed__c FROM Event_Attendee__c WHERE Contact__c = :a.Id];
        Assert.areEqual(1, att.size(), 'one attendance per event');
        Assert.isFalse(att[0].Communications_Allowed__c, 'the stricter choice wins');
        Assert.areEqual(1, [SELECT COUNT() FROM HCP_Affiliation__c WHERE Contact__c = :a.Id], 'same department folded');
        Assert.areEqual(DuplicateScanJob.STATUS_MERGED, [SELECT Status__c FROM HCP_Duplicate_Pair__c WHERE Id = :ab.Id].Status__c);
        HCP_Merge__c audit = [SELECT Merged_Contact_Id__c, Master_Contact_Id__c, Related_Summary__c, Field_Choices__c FROM HCP_Merge__c];
        Assert.areEqual(String.valueOf(b.Id), audit.Merged_Contact_Id__c);
        Assert.isTrue(audit.Related_Summary__c.startsWith('1 consents'), audit.Related_Summary__c);
        Assert.isTrue(audit.Field_Choices__c.contains('Registration_Number__c'));

        ConsentRecordController.EvidenceCheck check = ConsentRecordController.verifyEvidence(k.Id);
        Assert.isTrue(check.recordOk, check.message);
        Assert.areEqual(String.valueOf(b.Id), check.mergedFrom, check.message);

        Boolean immutable = false;
        try {
            update new HCP_Merge__c(Id = mergeId, Merged_Contact_Id__c = 'x');
        } catch (DmlException e) {
            immutable = true;
        }
        Assert.isTrue(immutable, 'merge audit is immutable');

        // a decided pair is not proposed again; it can be re-opened on purpose
        DuplicateScanJob.scanBlock('r');
        Assert.areEqual(DuplicateScanJob.STATUS_NOT_DUPLICATE, [SELECT Status__c FROM HCP_Duplicate_Pair__c WHERE Id = :cd.Id].Status__c);
        System.runAs(steward) {
            MatchingWorkbenchController.reopenPair(cd.Id);
            // runDuplicateScan / runGenerator only enqueue Batch Apex: a batch with several steps cannot run inside a test
        }
        Assert.areEqual(DuplicateScanJob.STATUS_OPEN, [SELECT Status__c FROM HCP_Duplicate_Pair__c WHERE Id = :cd.Id].Status__c);

        System.runAs(ConsentTestFactory.user(null)) {
            Boolean denied = false;
            try {
                MatchingWorkbenchController.getPairs(null, null, null, null);
            } catch (AuraHandledException e) {
                denied = true;
            }
            Assert.isTrue(denied, 'stewards only');
        }
    }
}
