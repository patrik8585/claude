// Pre-event registrations for every event except the volume test event (run after 03 and 05):
// 50 per congress, 20 per training meeting, all HCPs already in Salesforce (registrations come before the event):
// volume HCPs with their email or with a personal email + registration number; about 40% tick the consent.
// The congress also gets five named registrants used in the demo: Benedetti, Villa, Ferri (consent on file stays),
// Esposito of Rome (consent at registration), Marta Bianchi (no consent: the rep asks at check-in).
// Re-runnable: rows already imported are skipped. Matching runs a few seconds later (about a minute for all rows).
EventRegistrationService.ImportResult r = ConsentDemoData.registrations();
System.debug('Registrations imported: ' + r.imported + ', skipped: ' + r.skipped + ' ' + r.messages);
