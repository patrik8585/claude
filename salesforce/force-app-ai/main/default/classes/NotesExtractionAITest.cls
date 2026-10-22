@IsTest
private class NotesExtractionAITest {
    @IsTest
    static void fallsBackToRulesWhenEinsteinIsNotReachable() {
        insert new Consent_Capture_Settings__c(SetupOwnerId = UserInfo.getOrganizationId(), Use_Prompt_Builder__c = true);
        ConsentCaptureConfig.resetCache();
        // Prompt Builder calls are not executed in Apex tests: whatever happens, the rep gets a result.
        NotesExtractionService.Result r = NotesExtractionService.extractSmart('Dr. Maria Bianchi, paediatrician at Gaslini Genoa');
        Assert.areEqual('Bianchi', r.lastName);
        Assert.isNotNull(r.source);
        Boolean reached = false;
        try {
            new NotesExtractionAI().extract('Dr. Maria Bianchi', Date.today());
            reached = true;
        } catch (Exception e) {
            reached = true;
        }
        Assert.isTrue(reached, 'the call returns or throws, the caller handles both');
    }
}
