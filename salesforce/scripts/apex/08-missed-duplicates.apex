// Diagnostics: lists the known duplicates of the volume data (Contact.Test_Duplicate_Of__c) that the
// duplicate scan did NOT propose, with the engine's score and explanation. Read-only.
// Look for the lines starting with "MISSED" in the output.
List<Contact> dups = [
    SELECT Id, FirstName, LastName, Email, Specialty__c, MailingCity, Registration_Number__c, Registration_Key__c, OneKey_Id__c,
        AccountId, Account.Name, Test_Duplicate_Of__c
    FROM Contact
    WHERE Test_Duplicate_Of__c != NULL
];
Set<Id> originalIds = new Set<Id>();
Set<String> keys = new Set<String>();
for (Contact d : dups) {
    originalIds.add(d.Test_Duplicate_Of__c);
    keys.add(DuplicateScanJob.pairKey(d.Id, d.Test_Duplicate_Of__c));
}
originalIds.removeAll(new Map<Id, Contact>(dups).keySet());
Set<String> proposed = new Set<String>();
for (HCP_Duplicate_Pair__c p : [SELECT Pair_Key__c FROM HCP_Duplicate_Pair__c WHERE Pair_Key__c IN :keys]) {
    proposed.add(p.Pair_Key__c);
}
List<Contact> all = new List<Contact>(dups);
all.addAll([
    SELECT Id, FirstName, LastName, Email, Specialty__c, MailingCity, Registration_Number__c, Registration_Key__c, OneKey_Id__c,
        AccountId, Account.Name, Test_Duplicate_Of__c
    FROM Contact
    WHERE Id IN :originalIds
]);
Map<Id, HcpMatchEngine.Profile> profiles = HcpMatchEngine.fromContacts(all);
for (HcpMatchEngine.Profile p : profiles.values()) {
    p.prepare();
}
Map<Id, Contact> byId = new Map<Id, Contact>(all);
Integer missed = 0;
for (Contact d : dups) {
    if (proposed.contains(DuplicateScanJob.pairKey(d.Id, d.Test_Duplicate_Of__c))) {
        continue;
    }
    missed++;
    Contact o = byId.get(d.Test_Duplicate_Of__c);
    HcpMatchEngine.Comparison cmp = HcpMatchEngine.compare(profiles.get(d.Id), profiles.get(o.Id));
    System.debug(
        'MISSED ' + missed + ': ' + o.FirstName + ' ' + o.LastName + ' / ' + o.Email + ' / ' + o.Registration_Number__c + ' / ' + o.MailingCity +
        '  vs duplicate  ' + d.FirstName + ' ' + d.LastName + ' / ' + d.Email + ' / ' + d.Registration_Number__c + ' / ' + d.MailingCity +
        '  -> score ' + cmp.score + ', candidate ' + cmp.isCandidate() + ', min score ' + MatchingConfig.get().duplicateMinScore +
        ' | ' + cmp.explanationText()
    );
}
System.debug('MISSED total: ' + missed + ' of ' + dups.size() + ' known duplicates');
