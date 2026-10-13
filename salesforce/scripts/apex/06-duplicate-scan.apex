// Proposes duplicate HCP pairs (HCP_Duplicate_Pair__c) with the matching engine.
// Same as the "Run duplicate scan" button in the Matching & Duplicates tab.
Id jobId = DuplicateScanJob.run();
System.debug('Duplicate scan job: ' + jobId);
