@IsTest
private class PublicCaptureControllerTest {
    @TestSetup
    static void setup() {
        ConsentTestFactory.settings();
        ConsentTestFactory.event();
    }

    private static Event__c ev() {
        return [SELECT Id, Name FROM Event__c LIMIT 1];
    }

    private static PublicCaptureController.Submission validSubmission() {
        PublicCaptureController.Submission s = new PublicCaptureController.Submission();
        s.firstName = 'Laura';
        s.lastName = 'Benedetti';
        s.email = 'Laura.Benedetti@ospedale-example.it';
        s.specialty = 'Paediatrics';
        s.city = 'Padua';
        s.registrationNumber = 'PD-13350';
        s.consent = true;
        s.sendSlides = true;
        return s;
    }

    @IsTest
    static void formContextReturnsEventAndToken() {
        PublicCaptureController.FormContext ctx = PublicCaptureController.getFormContext(ev().Id);
        Assert.areEqual('Test Congress', ctx.eventName);
        Assert.isNotNull(ctx.formToken);
        Assert.isTrue(ctx.specialties.contains('Paediatrics'));
        Assert.isNotNull(ctx.consentText);
    }

    @IsTest
    static void formContextRejectsUnknownEvent() {
        Boolean failed = false;
        try {
            PublicCaptureController.getFormContext('not-an-id');
        } catch (AuraHandledException e) {
            failed = true;
        }
        Assert.isTrue(failed);
        Event__c e = ev();
        e.Public_Capture_Enabled__c = false;
        update e;
        failed = false;
        try {
            PublicCaptureController.getFormContext(e.Id);
        } catch (AuraHandledException ex) {
            failed = true;
        }
        Assert.isTrue(failed, 'disabled events are not public');
    }

    @IsTest
    static void submitCreatesCaptureAndMatchesAsync() {
        Event__c e = ev();
        String token = PublicCaptureController.getFormContext(e.Id).formToken;
        Test.startTest();
        PublicCaptureController.SubmitResult r = PublicCaptureController.submitCapture(e.Id, 'kiosk', token, validSubmission());
        Test.stopTest();
        Assert.isTrue(r.success, 'submit failed: ' + r.message);
        Assert.areEqual('Laura', r.firstName);
        Assert.isNotNull(r.nextFormToken);
        Capture__c c = [
            SELECT Channel__c, Opt_In_Status__c, Confirmation_Token_Hash__c, Confirmation_Email_Status__c, Matching_Status__c, Matched_Contact__c, Consent__c, Email__c
            FROM Capture__c
        ];
        Assert.areEqual(CaptureConstants.CHANNEL_KIOSK, c.Channel__c);
        Assert.areEqual(CaptureConstants.OPTIN_PENDING, c.Opt_In_Status__c);
        Assert.areEqual('laura.benedetti@ospedale-example.it', c.Email__c);
        Assert.isNotNull(c.Confirmation_Token_Hash__c);
        Assert.isTrue(c.Confirmation_Email_Status__c == CaptureConstants.EMAIL_SENT || c.Confirmation_Email_Status__c == CaptureConstants.EMAIL_FAILED);
        // no HCP in the org -> new HCP + pending consent
        Assert.areEqual(CaptureConstants.MATCH_NEW, c.Matching_Status__c);
        Assert.isNotNull(c.Matched_Contact__c);
        Assert.isNotNull(c.Consent__c);
    }

    @IsTest
    static void validationErrorsAreReported() {
        Event__c e = ev();
        String token = PublicCaptureController.getFormContext(e.Id).formToken;
        PublicCaptureController.Submission s = validSubmission();
        s.email = 'not-an-email';
        s.consent = false;
        s.specialty = 'Astrology';
        s.registrationNumber = '<script>';
        PublicCaptureController.SubmitResult r = PublicCaptureController.submitCapture(e.Id, 'qr', token, s);
        Assert.isFalse(r.success);
        Assert.isTrue(r.message.contains('work email'));
        Assert.isTrue(r.message.contains('consent'));
        Assert.isTrue(r.message.contains('specialty'));
        Assert.areEqual(0, [SELECT COUNT() FROM Capture__c]);
    }

    @IsTest
    static void honeypotAndBadTokenCreateNothing() {
        Event__c e = ev();
        String token = PublicCaptureController.getFormContext(e.Id).formToken;
        PublicCaptureController.Submission s = validSubmission();
        s.website = 'http://spam.example';
        Assert.isTrue(PublicCaptureController.submitCapture(e.Id, 'qr', token, s).success);
        Assert.isFalse(PublicCaptureController.submitCapture(e.Id, 'qr', 'forged|123|abc', validSubmission()).success);
        Assert.isFalse(PublicCaptureController.submitCapture(e.Id, 'qr', null, validSubmission()).success);
        Assert.isFalse(PublicCaptureController.submitCapture(null, 'qr', token, validSubmission()).success);
        Assert.areEqual(0, [SELECT COUNT() FROM Capture__c]);
    }

    @IsTest
    static void rateLimitPerEmail() {
        Consent_Capture_Settings__c s = Consent_Capture_Settings__c.getOrgDefaults();
        s.Max_Per_Email_Per_Day__c = 1;
        update s;
        ConsentCaptureConfig.resetCache();
        Event__c e = ev();
        String token = PublicCaptureController.getFormContext(e.Id).formToken;
        Assert.isTrue(PublicCaptureController.submitCapture(e.Id, 'qr', token, validSubmission()).success);
        PublicCaptureController.SubmitResult second = PublicCaptureController.submitCapture(e.Id, 'qr', token, validSubmission());
        Assert.isFalse(second.success);
        Assert.areEqual(1, [SELECT COUNT() FROM Capture__c]);
    }

    /** A real 1x1 PNG (the server checks the PNG signature bytes). */
    private static final String PNG_DATA_URL =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

    @IsTest
    static void kioskSignatureConfirmsConsentAtCapture() {
        Event__c e = ev();
        String token = PublicCaptureController.getFormContext(e.Id).formToken;
        PublicCaptureController.Submission s = validSubmission();
        s.signatureDataUrl = PNG_DATA_URL;
        s.deviceInfo = 'Test tablet';
        CaptureTriggerHandler.publishEnabled = false;
        PublicCaptureController.SubmitResult r = PublicCaptureController.submitCapture(e.Id, 'kiosk', token, s);
        Assert.isTrue(r.success, 'signed submit failed: ' + r.message);
        Assert.isTrue(r.signed, 'result must say signed');

        Capture__c c = [
            SELECT Id, Channel__c, Consent_Method__c, Opt_In_Status__c, Opt_In_Confirmed_At__c, Signature_Captured__c, Signature_Hash__c,
                Confirmation_Token_Hash__c, Confirmation_Email_Status__c, Capture_Device__c
            FROM Capture__c
        ];
        Assert.areEqual(CaptureConstants.CHANNEL_KIOSK, c.Channel__c);
        Assert.areEqual(CaptureConstants.METHOD_SIGNATURE, c.Consent_Method__c);
        Assert.areEqual(CaptureConstants.OPTIN_CONFIRMED, c.Opt_In_Status__c);
        Assert.isNotNull(c.Opt_In_Confirmed_At__c, 'confirmed at capture time');
        Assert.isTrue(c.Signature_Captured__c, 'signature flag set');
        Assert.areEqual(64, c.Signature_Hash__c.length(), 'SHA-256 hex of the PNG');
        Assert.isNull(c.Confirmation_Token_Hash__c, 'no double opt-in token when signed');
        Assert.areEqual(CaptureConstants.EMAIL_NOT_REQUIRED, c.Confirmation_Email_Status__c);
        Assert.isTrue(c.Capture_Device__c.startsWith('Kiosk'), 'device recorded: ' + c.Capture_Device__c);
        Assert.areEqual(1, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :c.Id], 'signature file on the capture');

        CaptureMatchingService.processCaptures(new Set<Id>{ c.Id });
        Capture__c after = [SELECT Consent__c FROM Capture__c WHERE Id = :c.Id];
        Assert.isNotNull(after.Consent__c, 'consent created by matching');
        Consent__c k = [SELECT Status__c, Opt_In_Method__c, Signature_Captured__c, Signature_Hash__c, Channel__c FROM Consent__c WHERE Id = :after.Consent__c];
        Assert.areEqual(CaptureConstants.CONSENT_CONFIRMED, k.Status__c);
        Assert.areEqual(CaptureConstants.METHOD_SIGNATURE, k.Opt_In_Method__c);
        Assert.isTrue(k.Signature_Captured__c, 'consent keeps the signature flag');
        Assert.areEqual(c.Signature_Hash__c, k.Signature_Hash__c);
        Assert.areEqual(CaptureConstants.CHANNEL_KIOSK, k.Channel__c);
    }

    @IsTest
    static void signatureOnlyAcceptedInKioskAndAsPng() {
        Event__c e = ev();
        String token = PublicCaptureController.getFormContext(e.Id).formToken;
        PublicCaptureController.Submission s = validSubmission();
        s.signatureDataUrl = PNG_DATA_URL;
        PublicCaptureController.SubmitResult qr = PublicCaptureController.submitCapture(e.Id, 'qr', token, s);
        Assert.isFalse(qr.success, 'no signature on the QR channel');
        Assert.isTrue(qr.message.contains('signature'), 'message names the signature: ' + qr.message);

        s.signatureDataUrl = ConsentTestFactory.signature();
        Assert.isFalse(PublicCaptureController.submitCapture(e.Id, 'kiosk', token, s).success, 'not a PNG');
        s.signatureDataUrl = 'data:text/html;base64,PGgxPmhpPC9oMT4=';
        Assert.isFalse(PublicCaptureController.submitCapture(e.Id, 'kiosk', token, s).success, 'wrong type');
        Assert.areEqual(0, [SELECT COUNT() FROM Capture__c]);

        Assert.isTrue(PublicCaptureController.isPngDataUrl(PNG_DATA_URL), 'valid PNG accepted');
        Assert.isFalse(PublicCaptureController.isPngDataUrl(null), 'blank rejected');
    }

    @IsTest
    static void doubleOptInConfirmation() {
        Event__c e = ev();
        CaptureTriggerHandler.publishEnabled = false;
        Capture__c c = ConsentTestFactory.capture(e, 'Marco', 'Ferri', 'marco.ferri@example.it', 'Paediatrics', 'Milan');
        String token = ConsentService.attachNewToken(c);
        insert c;
        CaptureMatchingService.processCaptures(new Set<Id>{ c.Id });

        PublicCaptureController.ConfirmationView v = PublicCaptureController.getConfirmation(token);
        Assert.areEqual('valid', v.status);
        Assert.areEqual('Ferri', v.lastName);

        v = PublicCaptureController.confirm(token);
        Assert.areEqual('confirmed', v.status);
        Assert.areEqual('https://example.com/slides.pdf', v.slidesUrl);

        Capture__c after = [SELECT Opt_In_Status__c, Consent__c, Matched_Contact__c FROM Capture__c WHERE Id = :c.Id];
        Assert.areEqual(CaptureConstants.OPTIN_CONFIRMED, after.Opt_In_Status__c);
        Consent__c k = [SELECT Status__c, Gigya_Status__c, Confirmed_At__c FROM Consent__c WHERE Id = :after.Consent__c];
        Assert.areEqual(CaptureConstants.CONSENT_CONFIRMED, k.Status__c);
        Assert.areEqual(CaptureConstants.GIGYA_QUEUED, k.Gigya_Status__c);
        Assert.areEqual(CaptureConstants.HCP_OPTIN, [SELECT Consent_Status__c FROM Contact WHERE Id = :after.Matched_Contact__c].Consent_Status__c);

        // confirming twice is harmless
        Assert.areEqual('confirmed', PublicCaptureController.confirm(token).status);
    }

    @IsTest
    static void invalidAndExpiredTokens() {
        Assert.areEqual('invalid', PublicCaptureController.getConfirmation('nope').status);
        Assert.areEqual('invalid', PublicCaptureController.confirm(ConsentService.newToken()).status);

        CaptureTriggerHandler.publishEnabled = false;
        Capture__c c = ConsentTestFactory.capture(ev(), 'Old', 'Link', 'old.link@example.it', 'Paediatrics', 'Milan');
        String token = ConsentService.attachNewToken(c);
        c.Token_Expires_At__c = System.now().addDays(-1);
        insert c;
        Assert.areEqual('expired', PublicCaptureController.confirm(token).status);
        Assert.areEqual(CaptureConstants.OPTIN_PENDING, [SELECT Opt_In_Status__c FROM Capture__c WHERE Id = :c.Id].Opt_In_Status__c);
    }

    @IsTest
    static void helpers() {
        Assert.areEqual('14–16 Oct 2026', PublicCaptureController.formatDates(Date.newInstance(2026, 10, 14), Date.newInstance(2026, 10, 16)));
        Assert.areEqual('13 Oct 2026', PublicCaptureController.formatDates(Date.newInstance(2026, 10, 13), null));
        Assert.areEqual('', PublicCaptureController.formatDates(null, null));
        Assert.isTrue(PublicCaptureController.formatDates(Date.newInstance(2026, 10, 30), Date.newInstance(2026, 11, 2)).contains('Nov'));
        Assert.areEqual('a b', PublicCaptureController.clean('  a\n<b ', 10));
        Event__c e = ev();
        String token = PublicCaptureController.issueFormToken(e.Id);
        Assert.isTrue(PublicCaptureController.verifyFormToken(token, e.Id));
        Assert.isFalse(PublicCaptureController.verifyFormToken(token + 'x', e.Id));
        Assert.isNull(ConsentService.findByToken('short'));
    }
}
