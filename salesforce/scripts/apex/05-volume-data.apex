// TEST ONLY: ~30 hospitals, ~170 departments, ~1,000 HCPs with hard cases, 150 test captures
// with expected outcomes. Runs as Batch Apex (about 2 minutes); progress in Setup > Apex Jobs.
// Re-runnable: it first deletes the previous volume data. The 14 mockup HCPs and the 2 events stay.
// Run 03-sample-data.apex first if you want the mockup data too.
Id jobId = VolumeTestData.generate();
System.debug('Volume test data job: ' + jobId);
