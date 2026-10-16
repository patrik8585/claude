// Deletes everything the volume generator created (Test_Data_Set__c = VOLUME / VOLUME-CAPTURES).
Id jobId = VolumeTestData.cleanup();
System.debug('Cleanup job: ' + jobId);
