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
}
