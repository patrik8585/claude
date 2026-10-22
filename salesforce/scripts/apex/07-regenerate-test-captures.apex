// After changing Setup > Custom Metadata Types > Matching Setting > Default:
// deletes the test captures (and the HCPs created from them) and creates them again for the size in the org,
// so matching runs with the new parameters. Then open Matching > Accuracy.
Id jobId = VolumeTestData.regenerateCaptures();
System.debug('Test captures job: ' + jobId);
