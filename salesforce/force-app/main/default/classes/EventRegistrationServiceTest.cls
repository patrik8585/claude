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
            first = EventRegistrationService.importRegistrations(e.Id, rows);
            CaptureMatchingService.processCaptures(registrationCaptureIds());
            again = EventRegistrationService.importRegistrations(e.Id, rows);
            summary = EventRegistrationService.getSummary(e.Id);
        }
        Assert.areEqual(3, first.imported, 'three valid, distinct rows: ' + first.messages);
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

        // Marchi: new HCP, registered
        Contact marchi = [SELECT Id, Consent_Status__c FROM Contact WHERE LastName = 'Marchi'];
        Assert.areEqual(CaptureConstants.HCP_OPTIN, marchi.Consent_Status__c);
        Assert.isTrue(attendee(marchi.Id).Registered__c, 'new HCP is registered');

        Assert.areEqual(3, summary.registered);
        Assert.areEqual(0, summary.checkedIn);
        Assert.areEqual(3, summary.notArrived);
        Assert.isTrue(summary.canImport, 'admin can import');
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
            RepCaptureController.addKnownHcp(e.Id, ferri.Id, null, null, 'test device');
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
    static void importNeedsStewardPermissionAndRows() {
        Event__c e = ev();
        User nobody = ConsentTestFactory.user(null);
        User admin = ConsentTestFactory.user('HCP_Consent_Admin');
        Boolean denied = false;
        Boolean empty = false;
        System.runAs(nobody) {
            try {
                EventRegistrationService.importRegistrations(e.Id, new List<EventRegistrationService.Registrant>{ row('A', 'B', null, false) });
            } catch (AuraHandledException ex) {
                denied = true;
            }
        }
        System.runAs(admin) {
            try {
                EventRegistrationService.importRegistrations(e.Id, new List<EventRegistrationService.Registrant>());
            } catch (AuraHandledException ex) {
                empty = true;
            }
        }
        Assert.isTrue(denied, 'users without the steward permission cannot import');
        Assert.isTrue(empty, 'an empty file is refused');
        Assert.areEqual(Date.newInstance(2026, 9, 20), EventRegistrationService.parseDate('2026-09-20').dateGmt());
        Assert.isNotNull(EventRegistrationService.parseDate('not a date'), 'bad dates fall back to now');
    }

    @IsTest
    static void demoRegistrations() {
        System.runAs(ConsentTestFactory.user('HCP_Consent_Admin')) {
            CaptureTriggerHandler.publishEnabled = false;
            delete [SELECT Id FROM Contact];
            ConsentDemoData.run();
            EventRegistrationService.ImportResult r = ConsentDemoData.registrations();
            Assert.areEqual(6, r.imported, 'six demo registrations: ' + r.messages);
        }
    }
}
