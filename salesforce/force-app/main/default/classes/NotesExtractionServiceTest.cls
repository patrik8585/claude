@IsTest
private class NotesExtractionServiceTest {
    private static final String DEMO = 'Dr. Maria Bianchi, paediatrician at Gaslini Genoa, interested in product X, call back in November. Email maria.bianchi@gmail.com';

    @IsTest
    static void extractsMockupNote() {
        NotesExtractionService.Result r = NotesExtractionService.extract(DEMO, Date.newInstance(2026, 10, 15));
        Assert.areEqual('Maria', r.firstName);
        Assert.areEqual('Bianchi', r.lastName);
        Assert.areEqual('maria.bianchi@gmail.com', r.email);
        Assert.areEqual('Paediatrics', r.specialty);
        Assert.areEqual('Genoa', r.city);
        Assert.areEqual('Gaslini', r.organisation);
        Assert.areEqual('Product X', r.interest);
        Assert.areEqual('Call back Dr. Maria Bianchi', r.taskTitle);
        Assert.areEqual(Date.newInstance(2026, 11, 2), r.taskDueDate);
        Assert.areEqual('Mon 2 Nov 2026', r.taskDueLabel);
        Assert.areEqual(8, r.fieldCount);
        Assert.areEqual(8, r.chips.size());
    }

    @IsTest
    static void defaultsAndEdgeCases() {
        NotesExtractionService.Result empty = NotesExtractionService.extract('');
        Assert.areEqual(0, empty.fieldCount);

        NotesExtractionService.Result r = NotesExtractionService.extract('Met Dr. Rossi from Milano, neonatologist.', Date.newInstance(2026, 10, 15));
        Assert.areEqual('Rossi', r.lastName);
        Assert.isNull(r.firstName);
        Assert.areEqual('Milan', r.city);
        Assert.areEqual('Neonatology', r.specialty);
        Assert.areEqual('Follow up with Dr. Rossi', r.taskTitle);
        Assert.areEqual(Date.newInstance(2026, 10, 29), r.taskDueDate);

        // month already past this year -> next year
        NotesExtractionService.Result jan = NotesExtractionService.extract('Dr. Luca Neri, call back in January', Date.newInstance(2026, 10, 15));
        Assert.areEqual(Date.newInstance(2027, 1, 4), jan.taskDueDate);
        Assert.areEqual(Date.newInstance(2026, 10, 5), NotesExtractionService.firstMondayOf(10, Date.newInstance(2026, 10, 1)));
    }

    @IsTest
    static void promptBuilderAnswerAndFallback() {
        Date today = Date.newInstance(2026, 10, 15);
        NotesExtractionService.Result r = NotesExtractionService.fromJson(
            'Here is the JSON: {"firstName":"Maria","lastName":"Bianchi","email":"Maria.Bianchi@gmail.com","specialty":"Paediatrics",' +
            '"city":"Genoa","organisation":"Gaslini","interest":"Product X","taskTitle":"Call back Dr. Maria Bianchi","taskDueDate":"2026-11-02"}',
            today
        );
        Assert.areEqual('maria.bianchi@gmail.com', r.email);
        Assert.areEqual(Date.newInstance(2026, 11, 2), r.taskDueDate);
        Assert.areEqual('Mon 2 Nov 2026', r.taskDueLabel);
        Assert.areEqual(7, r.fieldCount);

        NotesExtractionService.Result bad = NotesExtractionService.fromJson(
            '{"lastName":"Rossi","email":"not-an-email","specialty":"Astrology","taskDueDate":"yesterday"}',
            today
        );
        Assert.isNull(bad.email, 'malformed email dropped');
        Assert.isNull(bad.specialty, 'only picklist specialties');
        Assert.areEqual(today.addDays(14), bad.taskDueDate);
        Assert.areEqual('Follow up with Dr. Rossi', bad.taskTitle);
        Assert.areEqual(0, NotesExtractionService.fromJson('', today).fieldCount);

        Assert.areEqual('Rules', NotesExtractionService.extractSmart('Dr. Luca Neri').source, 'Prompt Builder off by default');
        insert new Consent_Capture_Settings__c(SetupOwnerId = UserInfo.getOrganizationId(), Use_Prompt_Builder__c = true);
        ConsentCaptureConfig.resetCache();
        NotesExtractionService.Result fb = NotesExtractionService.extractSmart('Dr. Luca Neri, call back in January');
        Assert.areEqual('Neri', fb.lastName, 'rules (or the template) always answer');
        Assert.isNotNull(fb.source);
    }
}
