@IsTest
private class EventRegistrationServiceTest {
    @TestSetup
    static void setup() {
        ConsentTestFactory.settings();
        ConsentTestFactory.event();
        ConsentTestFactory.contact('Marco', 'Ferri', 'marco.ferri@policlinico-example.it', 'Paediatrics', 'Milan', 'MI-20418');
        ConsentTestFactory.contact('Giulia', 'Romano', 'g.romano@ospedale-example.it', 'Neonatology', 'Rome', 'RM-33102');
    }

    private static Event__c ev() {
        return [SELECT Id FROM Event__c LIMIT 1];
    }

    private static EventRegistrationService.Registrant row(String first, String last, String email, Boolean consent) {
        EventRegistrationService.Registrant r = new EventRegistrationService.Registrant();
        r.firstName = first;
        r.lastName = last;
        r.email = email;
        r.specialty = 'Paediatrics';
        r.city = 'Florence';
        r.consent = consent;
        r.consentDate = '2026-09-20';
        return r;
    }

    private static Set<Id> registrationCaptureIds() {
        return new Map<Id, Capture__c>(
                [SELECT Id FROM Capture__c WHERE Channel__c = :CaptureConstants.CHANNEL_REGISTRATION]
            )
            .keySet();
    }

    private static Event_Attendee__c attendee(Id contactId) {
        return [SELECT Attendance_Status__c, Registered__c, Communications_Allowed__c FROM Event_Attendee__c WHERE Contact__c = :contactId];
    }

    @IsTest
    static void importMatchesAndKeepsExistingConsent() {
        Event__c e = ev();
        Contact ferri = [SELECT Id FROM Contact WHERE LastName = 'Ferri'];
        Contact romano = [SELECT Id FROM Contact WHERE LastName = 'Romano'];
        Consent__c onFile = ConsentTestFactory.confirmedConsent(ferri.Id);
        User admin = ConsentTestFactory.user('HCP_Consent_Admin');
        EventRegistrationService.ImportResult first;
        EventRegistrationService.ImportResult again;
        EventRegistrationService.Summary summary;
        System.runAs(admin) {
            CaptureTriggerHandler.publishEnabled = false;
            List<EventRegistrationService.Registrant> rows = new List<EventRegistrationService.Registrant>{
                row('Marco', 'Ferri', 'marco.ferri@policlinico-example.it', false),
                row('Giulia', 'Romano', 'g.romano@ospedale-example.it', true),
                row('Federica', 'Marchi', 'federica.marchi@meyer-example.it', true),
                row('Nolast', '', 'nolast@example.it', true),
                row('Marco', 'Ferri', 'MARCO.FERRI@policlinico-example.it', false)
            };
            first = EventRegistrationService.register(e.Id, rows);
            CaptureMatchingService.processCaptures(registrationCaptureIds());
            again = EventRegistrationService.register(e.Id, rows);
            summary = EventRegistrationService.getSummary(e.Id);
        }
        Assert.areEqual(3, first.imported, 'three valid, distinct rows: ' + first.messages);
        Assert.areEqual(0, [SELECT COUNT() FROM Contact WHERE LastName = 'Marchi'], 'a registration never creates a new HCP');
        Capture__c marchiReg = [SELECT Matching_Status__c, Match_Rule__c FROM Capture__c WHERE Last_Name__c = 'Marchi'];
        Assert.areEqual(CaptureConstants.MATCH_DISCARDED, marchiReg.Matching_Status__c, 'not in Salesforce -> discarded');
        Assert.areEqual(CaptureConstants.RULE_REGISTRATION_NOT_FOUND, marchiReg.Match_Rule__c);
        Assert.areEqual(2, first.skipped, 'missing last name + same email twice');
        Assert.areEqual(0, again.imported, 're-importing the same file adds nothing');

        // Ferri: registered, no consent ticked -> the consent on file stays
        Event_Attendee__c a1 = attendee(ferri.Id);
        Assert.areEqual(CaptureConstants.ATTENDANCE_REGISTERED, a1.Attendance_Status__c);
        Assert.isTrue(a1.Registered__c, 'registered flag set');
        Assert.isTrue(a1.Communications_Allowed__c, 'existing consent keeps communications allowed');
        Assert.areEqual(1, [SELECT COUNT() FROM Consent__c WHERE Contact__c = :ferri.Id], 'no new consent for Ferri');
        Assert.areEqual(onFile.Id, [SELECT Id FROM Consent__c WHERE Contact__c = :ferri.Id].Id);
        Assert.areEqual(CaptureConstants.HCP_OPTIN, [SELECT Consent_Status__c FROM Contact WHERE Id = :ferri.Id].Consent_Status__c);

        // Romano: consent given at registration -> confirmed consent with the registration channel
        Consent__c k = [SELECT Status__c, Channel__c, Opt_In_Method__c FROM Consent__c WHERE Contact__c = :romano.Id];
        Assert.areEqual(CaptureConstants.CONSENT_CONFIRMED, k.Status__c);
        Assert.areEqual(CaptureConstants.CHANNEL_REGISTRATION, k.Channel__c);
        Assert.areEqual(CaptureConstants.METHOD_REGISTRATION, k.Opt_In_Method__c);
        Assert.areEqual(CaptureConstants.HCP_OPTIN, [SELECT Consent_Status__c FROM Contact WHERE Id = :romano.Id].Consent_Status__c);

        Assert.areEqual(2, summary.registered, 'Ferri and Romano; Marchi is not in Salesforce');
        Assert.areEqual(0, summary.checkedIn);
        Assert.areEqual(2, summary.notArrived);
        Assert.areEqual(1, summary.notFound, 'Marchi reported as not in Salesforce');
    }

    @IsTest
    static void repCheckInTurnsRegisteredIntoAttended() {
        Event__c e = ev();
        Contact ferri = [SELECT Id FROM Contact WHERE LastName = 'Ferri'];
        ConsentTestFactory.confirmedConsent(ferri.Id);
        insert new Event_Attendee__c(
            Event__c = e.Id,
            Contact__c = ferri.Id,
            Attendee_Key__c = CaptureResolutionService.attendeeKey(e.Id, ferri.Id),
            Attendance_Status__c = CaptureConstants.ATTENDANCE_REGISTERED,
            Registered__c = true,
            Communications_Allowed__c = true
        );
        User rep = ConsentTestFactory.user('HCP_Consent_Rep');
        RepCaptureController.RegisteredList listBefore;
        List<RepCaptureController.HcpResult> found;
        System.runAs(rep) {
            CaptureTriggerHandler.publishEnabled = false;
            listBefore = RepCaptureController.getRegisteredAttendees(e.Id);
            found = RepCaptureController.searchHcps('Ferri', e.Id);
            RepCaptureController.addKnownHcp(e.Id, ferri.Id, null, null, 'test device', null);
        }
        Assert.areEqual(1, listBefore.registered);
        Assert.areEqual(0, listBefore.checkedIn);
        Assert.areEqual('registered', listBefore.attendees[0].attendance);
        Assert.areEqual('registered', found[0].attendance, 'search shows the registration');

        Set<Id> repCaptures = new Map<Id, Capture__c>([SELECT Id FROM Capture__c WHERE Channel__c = :CaptureConstants.CHANNEL_REP]).keySet();
        CaptureMatchingService.processCaptures(repCaptures);
        Event_Attendee__c a = attendee(ferri.Id);
        Assert.areEqual(CaptureConstants.ATTENDANCE_ATTENDED, a.Attendance_Status__c, 'checked in');
        Assert.isTrue(a.Registered__c, 'still counted as registered');

        // a later registration import never turns an attendee back into Registered
        EventRegistrationService.register(e.Id, new List<EventRegistrationService.Registrant>{ row('Marco', 'Ferri', 'marco.ferri@policlinico-example.it', false) });
        CaptureMatchingService.processCaptures(registrationCaptureIds());
        Assert.areEqual(CaptureConstants.ATTENDANCE_ATTENDED, attendee(ferri.Id).Attendance_Status__c, 'no downgrade');

        CaptureDashboardController.Stats stats = CaptureDashboardController.getStats(e.Id);
        Assert.areEqual(1, stats.registered);
        Assert.areEqual(1, stats.checkedIn);
        Assert.areEqual(1, stats.total, 'registration captures are not counted as event captures');
    }

    @IsTest
    static void attendeeTypeTellsRegisteredFromWalkIns() {
        Event__c e = ev();
        Contact ferri = [SELECT Id FROM Contact WHERE LastName = 'Ferri'];
        Contact romano = [SELECT Id FROM Contact WHERE LastName = 'Romano'];
        CaptureTriggerHandler.publishEnabled = false;
        EventRegistrationService.register(e.Id, new List<EventRegistrationService.Registrant>{ row('Giulia', 'Romano', 'g.romano@ospedale-example.it', false) });
        Capture__c known = ConsentTestFactory.capture(e, 'Marco', 'Ferri', 'marco.ferri@policlinico-example.it', 'Paediatrics', 'Milan');
        Capture__c unknown = ConsentTestFactory.capture(e, 'Ottavia', 'Quaglierini', 'ottavia.q@gmail.com', 'Paediatrics', 'Bergamo');
        insert new List<Capture__c>{ known, unknown };
        Set<Id> ids = registrationCaptureIds();
        ids.add(known.Id);
        ids.add(unknown.Id);
        CaptureMatchingService.processCaptures(ids);
        Assert.areEqual('Registered', [SELECT Attendee_Type__c FROM Event_Attendee__c WHERE Contact__c = :romano.Id].Attendee_Type__c);
        Assert.areEqual('Walk-in - known HCP', [SELECT Attendee_Type__c FROM Event_Attendee__c WHERE Contact__c = :ferri.Id].Attendee_Type__c);
        Contact created = [SELECT Id FROM Contact WHERE LastName = 'Quaglierini'];
        Assert.areEqual('Walk-in - new HCP', [SELECT Attendee_Type__c FROM Event_Attendee__c WHERE Contact__c = :created.Id].Attendee_Type__c);
    }

    @IsTest
    static void registeredCandidateGetsBonus() {
        Event__c e = ev();
        Contact romano = [SELECT Id FROM Contact WHERE LastName = 'Romano'];
        insert new Event_Attendee__c(
            Event__c = e.Id,
            Contact__c = romano.Id,
            Attendee_Key__c = CaptureResolutionService.attendeeKey(e.Id, romano.Id),
            Attendance_Status__c = CaptureConstants.ATTENDANCE_REGISTERED,
            Registered__c = true
        );
        CaptureTriggerHandler.publishEnabled = false;
        Capture__c typo = ConsentTestFactory.capture(e, 'Giulia', 'Romanno', 'giulia.r@gmail.com', 'Neonatology', 'Rome');
        insert typo;
        CaptureMatchingService.processCaptures(new Set<Id>{ typo.Id });
        Capture_Candidate__c top = [
            SELECT Contact__c, Score_Explanation__c
            FROM Capture_Candidate__c
            WHERE Capture__c = :typo.Id AND Recommended__c = TRUE
        ];
        Assert.areEqual(romano.Id, top.Contact__c);
        Assert.isTrue(top.Score_Explanation__c.contains('registered for this event'), top.Score_Explanation__c);
    }

    @IsTest
    static void manualRegisteredAttendeeIsCounted() {
        Event__c e = ev();
        Contact romano = [SELECT Id FROM Contact WHERE LastName = 'Romano'];
        // entered by hand on the congress page: only the status is chosen
        Event_Attendee__c a = new Event_Attendee__c(
            Event__c = e.Id,
            Contact__c = romano.Id,
            Attendee_Key__c = CaptureResolutionService.attendeeKey(e.Id, romano.Id),
            Attendance_Status__c = CaptureConstants.ATTENDANCE_REGISTERED
        );
        insert a;
        Assert.isTrue(attendee(romano.Id).Registered__c, 'flag set from the status');
        Assert.areEqual(1, EventRegistrationService.getSummary(e.Id).registered, 'counted as registered');
        update new Event_Attendee__c(Id = a.Id, Attendance_Status__c = CaptureConstants.ATTENDANCE_ATTENDED);
        EventRegistrationService.Summary s = EventRegistrationService.getSummary(e.Id);
        Assert.isTrue(attendee(romano.Id).Registered__c, 'still registered after check-in');
        Assert.areEqual(1, s.checkedIn, 'registered and checked in');
        Assert.areEqual(0, s.walkIns, 'not a walk-in');
    }

    @IsTest
    static void registrationDates() {
        Assert.areEqual(Date.newInstance(2026, 9, 20), EventRegistrationService.parseDate('2026-09-20').dateGmt(), 'yyyy-MM-dd parsed');
        Assert.isNotNull(EventRegistrationService.parseDate('not a date'), 'bad dates fall back to now');
    }

    @IsTest
    static void demoRegistrations() {
        System.runAs(ConsentTestFactory.user('HCP_Consent_Admin')) {
            CaptureTriggerHandler.publishEnabled = false;
            delete [SELECT Id FROM Contact];
            delete [SELECT Id FROM Event__c];
            ConsentDemoData.run();
            EventRegistrationService.ImportResult r = ConsentDemoData.registrations();
            Assert.isTrue(r.imported >= 5, 'named congress registrants plus mockup HCPs: ' + r.messages);
            Assert.areEqual(0, [SELECT COUNT() FROM Capture__c WHERE Channel__c = :CaptureConstants.CHANNEL_REGISTRATION AND Last_Name__c = 'Conti'], 'opted-out HCPs are not used');
            EventRegistrationService.ImportResult again = ConsentDemoData.registrations();
            Assert.areEqual(0, again.imported, 're-running adds nothing');
        }
    }
}
