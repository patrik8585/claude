@IsTest
private class MatchingWorkbenchTest {
    private static User admin() {
        return ConsentTestFactory.user('HCP_Consent_Admin');
    }

    @IsTest
    static void devSizeFitsADeveloperEdition() {
        VolumeTestData.small = false;
        VolumeTestData.size = VolumeTestData.SIZE_DEV;
        VolumeTestData.Plan plan = new VolumeTestData.Plan();
        Assert.areEqual(10, plan.hospitals.size(), 'every third hospital');
        Assert.areEqual(15, plan.duplicates.size(), 'DEV duplicates');
        Assert.areEqual(59, plan.captures.size(), 'DEV test captures');
        Assert.isTrue(plan.hcps.size() > 150 && plan.hcps.size() < 400, 'about 260 HCPs: ' + plan.hcps.size());
        Integer departments = 0;
        for (VolumeTestData.HospitalSpec h : plan.hospitals) {
            departments += h.departments.size();
        }
        // HCP + ~1.1 affiliations each, accounts, captures with ~4 candidates each: well under 5 MB at 2 KB per record
        Integer records = plan.hcps.size() * 2 + plan.duplicates.size() * 2 + plan.hospitals.size() + departments + plan.captures.size() * 6;
        Assert.isTrue(records < 1300, 'about 2.5 MB at most: ' + records + ' records');
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
        }
        Assert.areEqual('Typo', VolumeTestData.typo('Typpo'));
        Assert.areEqual('Csota', VolumeTestData.typo('Costa'));
        Assert.isTrue(HcpMatchEngine.isTransposition('costa', 'csota'));
        Assert.areEqual('Nicolo', VolumeTestData.stripAccents('Nicolò'));
        Assert.areEqual(VolumeTestData.OUT_REVIEW, MatchingAccuracyController.actualOutcome(CaptureConstants.MATCH_REVIEWED_NEW));
    }

    @IsTest
    static void reviewQueueForStewardsOnly() {
        ConsentTestFactory.settings();
        Event__c ev = ConsentTestFactory.event();
        Account hosp;
        Contact maria;
        System.runAs(admin()) {
            hosp = ConsentTestFactory.hospital('Gaslini Institute', 'Genoa', 'gaslini-example.it', 'Gaslini');
            Account dept = ConsentTestFactory.department(hosp, 'Paediatrics');
            maria = ConsentTestFactory.contactAt('Maria', 'Bianchi', 'm.bianchi@gaslini-example.it', 'Paediatrics', 'Genoa', 'GE-11873', dept.Id);
        }
        CaptureTriggerHandler.publishEnabled = false;
        // personal email, no registration number: same name -> a person decides
        Capture__c cap = ConsentTestFactory.capture(ev, 'Maria', 'Bianchi', 'maria.bianchi.ge@gmail.com', 'Paediatrics', 'Genoa');
        insert cap;
        CaptureMatchingService.processCaptures(new Set<Id>{ cap.Id });
        Assert.areEqual(CaptureConstants.MATCH_REVIEW, [SELECT Matching_Status__c FROM Capture__c WHERE Id = :cap.Id].Matching_Status__c, 'namesake goes to review');

        List<MatchingWorkbenchController.QueueRow> rows;
        User steward = ConsentTestFactory.user('HCP_Consent_Data_Steward');
        System.runAs(steward) {
            Assert.isTrue(MatchingWorkbenchController.getHcoOptions().size() >= 2, 'hospital and department');
            rows = MatchingWorkbenchController.getReviewQueue(null, null);
        }
        Assert.areEqual(1, rows.size(), 'one capture to review');
        Assert.areEqual(String.valueOf(cap.Id), rows[0].id, 'the capture');
        Assert.isTrue(rows[0].topCandidate.contains('Bianchi'), 'recommended HCP shown: ' + rows[0].topCandidate);

        // per-congress figures are read live: one auto-match by email, one capture waiting for review
        Capture__c exact = ConsentTestFactory.capture(ev, 'Maria', 'Bianchi', 'm.bianchi@gaslini-example.it', 'Paediatrics', 'Genoa');
        insert exact;
        CaptureMatchingService.processCaptures(new Set<Id>{ exact.Id });
        MatchingAccuracyController.EventMetrics atStart;
        MatchingAccuracyController.EventMetrics afterReview;
        MatchingAccuracyController.EventMetrics allEvents;
        List<MatchingAccuracyController.EventOption> options;
        System.runAs(steward) {
            atStart = MatchingAccuracyController.getEventMetrics(ev.Id);
            CaptureReviewController.matchToContact(cap.Id, maria.Id);
            afterReview = MatchingAccuracyController.getEventMetrics(ev.Id);
            allEvents = MatchingAccuracyController.getEventMetrics(null);
            options = MatchingAccuracyController.getEventOptions();
        }
        Assert.areEqual(2, atStart.total, 'two captures at the congress');
        Assert.areEqual(1, atStart.autoCount, 'exact email auto-matched');
        Assert.areEqual(1, atStart.autoByEmail, 'by the email rule');
        Assert.areEqual(1, atStart.sentToReview, 'namesake sent to review');
        Assert.areEqual(1, atStart.backlog, 'still waiting');
        Assert.isNotNull(atStart.avgTopScore, 'score of the recommended candidate');
        Assert.areEqual(0, afterReview.backlog, 'review done');
        Assert.areEqual(1, afterReview.reviewedMatched, 'matched by the steward');
        Assert.areEqual(1, afterReview.recommendationAccepted, 'the recommended HCP was chosen');
        Assert.isTrue(afterReview.recommendationAcceptedRate == 100, 'acceptance rate: ' + afterReview.recommendationAcceptedRate);
        Assert.areEqual(1, allEvents.byEvent.size(), 'one row per congress');
        Assert.areEqual(2, allEvents.total, 'all congresses');
        Assert.areEqual(1, options.size(), 'one congress');
        Assert.areEqual(2, options[0].captures, 'with its captures');

        System.runAs(ConsentTestFactory.user(null)) {
            Boolean denied = false;
            try {
                MatchingWorkbenchController.getReviewQueue(null, null);
            } catch (AuraHandledException e) {
                denied = true;
            }
            Assert.isTrue(denied, 'stewards only');
        }
    }
}
