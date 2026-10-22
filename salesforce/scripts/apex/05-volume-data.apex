// TEST ONLY: volume data with hard cases and test captures with expected outcomes.
// Default size DEV fits a Developer Edition (5 MB data storage): 10 hospitals, ~55 departments,
// ~260 HCPs, 15 real duplicates, 59 test captures (about 2 MB).
// In a sandbox use VolumeTestData.generate('FULL') instead: 30 hospitals, ~1,000 HCPs, 150 captures (about 7 MB).
// Runs as Batch Apex (1-2 minutes); progress in Setup > Apex Jobs.
// Re-runnable: it first deletes the previous volume data (and empties it from the Recycle Bin).
// The 14 mockup HCPs and the 2 events stay. Run 03-sample-data.apex first if you want the mockup data too.
Id jobId = VolumeTestData.generate();
System.debug('Volume test data job: ' + jobId);
