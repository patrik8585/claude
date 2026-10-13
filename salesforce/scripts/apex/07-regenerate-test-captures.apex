// After changing Setup > Custom Metadata Types > Matching Setting > Default:
// deletes the 150 test captures (and the HCPs created from them) and creates them again,
// so matching runs with the new parameters. Then open Matching & Duplicates > Accuracy.
Id jobId = VolumeTestData.regenerateCaptures();
System.debug('Test captures job: ' + jobId);
