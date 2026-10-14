// Pre-event registrations for the congress (run after 03-sample-data.apex):
// Benedetti, Villa and Ferri (already have consent, do not tick it again: their consent stays),
// Esposito (Rome) gives consent at registration, Federica Marchi (new, consent) and Tommaso Galli (new, no consent).
// Matching runs a few seconds later; then open the rep page > congress > "Show registered list".
EventRegistrationService.ImportResult r = ConsentDemoData.registrations();
System.debug('Registrations imported: ' + r.imported + ', skipped: ' + r.skipped + ' ' + r.messages);
