// Pre-event registrations for every event except the volume test event (run after 03-sample-data.apex,
// best after 05-volume-data.apex so that existing HCPs register too): 50 per congress, 20 per training meeting.
// Mix: existing HCPs with their email (auto-matched), existing HCPs with a personal email + registration number,
// new people (new HCPs); about 40% tick the consent. The congress also gets six named registrants used in the demo:
// Benedetti, Villa, Ferri (consent on file stays), Esposito (consent at registration), Marchi and Galli (new).
// Re-runnable: rows already imported are skipped. Matching runs a few seconds later (about a minute for all rows).
EventRegistrationService.ImportResult r = ConsentDemoData.registrations();
System.debug('Registrations imported: ' + r.imported + ', skipped: ' + r.skipped + ' ' + r.messages);
