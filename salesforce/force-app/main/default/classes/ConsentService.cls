/**
 * Double opt-in tokens and emails, confirmation, and the Contact consent summary.
 * Runs without sharing: callers (guest controller, rep controller, matching) validate input first.
 */
public without sharing class ConsentService {
    private static final Pattern TOKEN_PATTERN = Pattern.compile('^[0-9a-f]{64}$');

    // ------------------------------------------------------------ tokens

    public static String newToken() {
        return EncodingUtil.convertToHex(Crypto.generateAesKey(256));
    }

    public static String hashToken(String token) {
        return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(token)));
    }

    public static Boolean isWellFormedToken(String token) {
        return token != null && TOKEN_PATTERN.matcher(token).matches();
    }

    /** Sets token hash and expiry on the capture (not yet saved) and returns the raw token. */
    public static String attachNewToken(Capture__c capture) {
        String token = newToken();
        capture.Confirmation_Token_Hash__c = hashToken(token);
        capture.Token_Expires_At__c = System.now().addDays(ConsentCaptureConfig.tokenValidityDays());
        return token;
    }

    public static Capture__c findByToken(String token) {
        if (!isWellFormedToken(token)) {
            return null;
        }
        String hash = hashToken(token);
        List<Capture__c> rows = [
            SELECT
                Id,
                Name,
                First_Name__c,
                Last_Name__c,
                Email__c,
                Opt_In_Status__c,
                Opt_In_Confirmed_At__c,
                Token_Expires_At__c,
                Send_Slides__c,
                Consent__c,
                Consent_Text_Version__c,
                Processing_Stage__c,
                Event__r.Name,
                Event__r.Short_Name__c,
                Event__r.Slides_Url__c
            FROM Capture__c
            WHERE Confirmation_Token_Hash__c = :hash
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    // ------------------------------------------------------------ email

    public static String confirmationLink(String token) {
        String base = ConsentCaptureConfig.publicSiteUrl();
        if (String.isBlank(base)) {
            return null;
        }
        // Lightning app pages (internal preview) only keep c__-prefixed parameters
        String param = base.contains('/lightning/') ? 'c__t=' : 't=';
        return base + (base.contains('?') ? '&' : '?') + param + token;
    }

    /** Why the last confirmation / signed-copy email was not sent (null after a successful send). */
    public static String lastEmailError;

    private static Boolean failed(String reason) {
        lastEmailError = reason == null ? 'Unknown error' : reason.left(255);
        System.debug(LoggingLevel.WARN, 'Email not sent: ' + lastEmailError);
        return false;
    }

    private static Boolean outcome(List<Messaging.SendEmailResult> results) {
        if (results.isEmpty()) {
            return failed('No send result returned');
        }
        if (results[0].isSuccess()) {
            lastEmailError = null;
            return true;
        }
        Messaging.SendEmailError err = results[0].getErrors().isEmpty() ? null : results[0].getErrors()[0];
        return failed(err == null ? 'Send failed' : String.valueOf(err.getStatusCode()) + ': ' + err.getMessage());
    }

    /**
     * Sends the double opt-in email. Never throws: returns false when the link
     * cannot be built or the org email limit / deliverability blocks the send.
     */
    public static Boolean sendConfirmationEmail(String toAddress, String lastName, String eventName, String token) {
        String link = confirmationLink(token);
        if (String.isBlank(toAddress)) {
            return failed('No email address');
        }
        if (link == null) {
            return failed('Public site URL not configured: run scripts/apex/01-configure.apex with the site URL');
        }
        try {
            Messaging.reserveSingleEmailCapacity(1);
            ConsentCaptureConfig.ConsentText text = ConsentCaptureConfig.activeConsentText();
            String safeName = String.isBlank(lastName) ? '' : lastName.escapeHtml4();
            String safeEvent = String.isBlank(eventName) ? 'our event' : eventName.escapeHtml4();
            String html =
                '<p>Dear Dr. ' + safeName + ',</p>' +
                '<p>Thank you for visiting us at the <b>' + safeEvent + '</b>. ' +
                'Please confirm that you agree to receive our scientific communications and we will send you the slides.</p>' +
                '<p><a href="' + link + '" style="display:inline-block;background:#0176d3;color:#ffffff;padding:12px 20px;border-radius:4px;text-decoration:none;font-weight:bold">' +
                'Confirm my email &amp; get the slides</a></p>' +
                '<p style="color:#706e6b;font-size:12px">' + text.body.escapeHtml4() + '<br/>Consent text ' + text.version.escapeHtml4() + '.</p>' +
                '<p style="color:#706e6b;font-size:12px">If you did not request this, ignore this email: nothing will be recorded as consent.</p>';
            String plain =
                'Dear Dr. ' + (lastName == null ? '' : lastName) + ',\n\n' +
                'Please confirm your email to get the slides: ' + link + '\n\n' +
                text.body + '\nConsent text ' + text.version + '.';

            Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
            mail.setToAddresses(new List<String>{ toAddress });
            mail.setSubject('Please confirm your email to get the slides');
            mail.setHtmlBody(html);
            mail.setPlainTextBody(plain);
            mail.setSaveAsActivity(false);
            mail.setUseSignature(false);
            Id oweaId = orgWideAddressId();
            if (oweaId != null) {
                mail.setOrgWideEmailAddressId(oweaId);
            } else {
                String sender = ConsentCaptureConfig.settings().Email_Sender_Name__c;
                mail.setSenderDisplayName(String.isBlank(sender) ? 'Danone Events' : sender);
            }
            return outcome(Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ mail }, false));
        } catch (Exception e) {
            return failed(e.getMessage());
        }
    }

    private static Id orgWideAddressId() {
        String address = ConsentCaptureConfig.settings().Org_Wide_Email_Address__c;
        if (String.isBlank(address)) {
            return null;
        }
        List<OrgWideEmailAddress> rows = [SELECT Id FROM OrgWideEmailAddress WHERE Address = :address LIMIT 1];
        return rows.isEmpty() ? null : rows[0].Id;
    }

    // ------------------------------------------------------------ confirmation

    /**
     * Confirms the double opt-in for the capture behind the token.
     * Returns the refreshed capture, or null when the token is unknown.
     * Expired tokens are not confirmed (caller checks Token_Expires_At__c).
     */
    public static Capture__c confirm(Capture__c capture) {
        if (capture.Opt_In_Status__c == CaptureConstants.OPTIN_CONFIRMED) {
            return capture;
        }
        Datetime now = System.now();
        capture.Opt_In_Status__c = CaptureConstants.OPTIN_CONFIRMED;
        capture.Opt_In_Confirmed_At__c = now;
        Capture__c upd = new Capture__c(Id = capture.Id, Opt_In_Status__c = CaptureConstants.OPTIN_CONFIRMED, Opt_In_Confirmed_At__c = now);

        if (capture.Consent__c != null) {
            Consent__c consent = [SELECT Id, Contact__c, Status__c FROM Consent__c WHERE Id = :capture.Consent__c];
            if (consent.Status__c == CaptureConstants.CONSENT_PENDING) {
                consent.Status__c = CaptureConstants.CONSENT_CONFIRMED;
                consent.Confirmed_At__c = now;
                consent.Gigya_Status__c = CaptureConstants.GIGYA_QUEUED;
                update consent;
                if (consent.Contact__c != null) {
                    refreshContactSummary(new Set<Id>{ consent.Contact__c });
                }
            }
        }
        update upd;
        return capture;
    }

    // ------------------------------------------------------------ contact summary

    /**
     * Recomputes Contact.Consent_Status__c from the Consent__c records:
     * a confirmed consent newer than the last withdrawal = Opt-in; otherwise a withdrawal = Opted out;
     * otherwise a pending consent = Pending; otherwise None.
     */
    public static void refreshContactSummary(Set<Id> contactIds) {
        contactIds.remove(null);
        if (contactIds.isEmpty()) {
            return;
        }
        Map<Id, List<Consent__c>> byContact = new Map<Id, List<Consent__c>>();
        for (Consent__c c : [
            SELECT Id, Contact__c, Status__c, Captured_At__c, Confirmed_At__c, Withdrawn_At__c, Consent_Text_Version__c
            FROM Consent__c
            WHERE Contact__c IN :contactIds
        ]) {
            if (!byContact.containsKey(c.Contact__c)) {
                byContact.put(c.Contact__c, new List<Consent__c>());
            }
            byContact.get(c.Contact__c).add(c);
        }
        List<Contact> updates = new List<Contact>();
        for (Contact ct : [SELECT Id, Consent_Status__c FROM Contact WHERE Id IN :contactIds]) {
            List<Consent__c> consents = byContact.containsKey(ct.Id) ? byContact.get(ct.Id) : new List<Consent__c>();
            Consent__c lastConfirmed;
            Consent__c lastWithdrawn;
            Consent__c lastPending;
            for (Consent__c c : consents) {
                if (c.Status__c == CaptureConstants.CONSENT_CONFIRMED && c.Confirmed_At__c != null) {
                    if (lastConfirmed == null || c.Confirmed_At__c > lastConfirmed.Confirmed_At__c) {
                        lastConfirmed = c;
                    }
                } else if (c.Status__c == CaptureConstants.CONSENT_WITHDRAWN && c.Withdrawn_At__c != null) {
                    if (lastWithdrawn == null || c.Withdrawn_At__c > lastWithdrawn.Withdrawn_At__c) {
                        lastWithdrawn = c;
                    }
                } else if (c.Status__c == CaptureConstants.CONSENT_PENDING) {
                    if (lastPending == null || (c.Captured_At__c != null && lastPending.Captured_At__c != null && c.Captured_At__c > lastPending.Captured_At__c)) {
                        lastPending = c;
                    }
                }
            }
            Contact upd = new Contact(Id = ct.Id);
            if (lastConfirmed != null && (lastWithdrawn == null || lastConfirmed.Confirmed_At__c > lastWithdrawn.Withdrawn_At__c)) {
                upd.Consent_Status__c = CaptureConstants.HCP_OPTIN;
                upd.Consent_Status_Date__c = lastConfirmed.Confirmed_At__c.date();
                upd.Consent_Text_Version__c = lastConfirmed.Consent_Text_Version__c;
            } else if (lastWithdrawn != null) {
                upd.Consent_Status__c = CaptureConstants.HCP_OPTOUT;
                upd.Consent_Status_Date__c = lastWithdrawn.Withdrawn_At__c.date();
                upd.Consent_Text_Version__c = lastWithdrawn.Consent_Text_Version__c;
            } else if (lastPending != null) {
                upd.Consent_Status__c = CaptureConstants.HCP_PENDING;
                upd.Consent_Status_Date__c = lastPending.Captured_At__c == null ? null : lastPending.Captured_At__c.date();
                upd.Consent_Text_Version__c = lastPending.Consent_Text_Version__c;
            } else if (ct.Consent_Status__c == CaptureConstants.HCP_OPTOUT) {
                // Opt-out recorded outside this solution (no Consent__c record): keep it.
                continue;
            } else {
                upd.Consent_Status__c = CaptureConstants.HCP_NONE;
                upd.Consent_Status_Date__c = null;
                upd.Consent_Text_Version__c = null;
            }
            updates.add(upd);
        }
        if (!updates.isEmpty()) {
            // duplicate HCPs (same person entered twice) must still get their summary
            Database.update(updates, CaptureResolutionService.allowDuplicates());
        }
    }

    // ------------------------------------------------------------ signature and evidence

    public static String sha256Hex(Blob data) {
        return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', data));
    }

    /**
     * Stores a PNG data URL (from the signature canvas) as a file on the capture
     * and returns the SHA-256 of the image bytes (kept on the capture and the consent).
     */
    public static String saveSignature(Id captureId, String captureName, String dataUrl) {
        if (String.isBlank(dataUrl)) {
            return null;
        }
        String b64 = dataUrl.contains(',') ? dataUrl.substringAfter(',') : dataUrl;
        if (b64.length() > 2000000) {
            throw new IllegalArgumentException('Signature image too large.');
        }
        Blob png = EncodingUtil.base64Decode(b64);
        ContentVersion cv = new ContentVersion(
            Title = 'Consent signature - ' + captureName,
            PathOnClient = 'signature.png',
            VersionData = png,
            FirstPublishLocationId = captureId
        );
        insert cv;
        return sha256Hex(png);
    }

    /**
     * SHA-256 over the consent evidence: HCP, capture time (to the second, GMT), consent text and version,
     * opt-in method, signature hash, captured by, source capture. Recomputed by "Verify evidence".
     */
    public static String evidenceHash(Consent__c k) {
        List<String> parts = new List<String>{
            str(k.Contact__c),
            k.Captured_At__c == null ? '' : k.Captured_At__c.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\''),
            str(k.Consent_Text_Version__c),
            str(k.Consent_Text__c),
            str(k.Opt_In_Method__c),
            str(k.Signature_Hash__c),
            str(k.Captured_By__c),
            str(k.Source_Capture__c)
        };
        return sha256Hex(Blob.valueOf(String.join(parts, '|')));
    }

    private static String str(Object o) {
        return o == null ? '' : String.valueOf(o);
    }

    /** Emails the HCP a copy of the consent just signed on the rep's device. Never throws. */
    public static Boolean sendSignedCopyEmail(String toAddress, String lastName, String eventName, Datetime signedAt, String repName) {
        return sendSignedCopyEmail(toAddress, lastName, eventName, signedAt, repName, null);
    }

    /**
     * Same, with an optional slides link (kiosk: the HCP asked for the slides and signed on screen,
     * so there is no confirmation page to show them). repName null = signed at the kiosk. Never throws.
     */
    public static Boolean sendSignedCopyEmail(
        String toAddress,
        String lastName,
        String eventName,
        Datetime signedAt,
        String repName,
        String slidesUrl
    ) {
        if (String.isBlank(toAddress)) {
            return failed('No email address');
        }
        try {
            Messaging.reserveSingleEmailCapacity(1);
            ConsentCaptureConfig.ConsentText text = ConsentCaptureConfig.activeConsentText();
            String signedOn = signedAt == null ? '' : signedAt.format('d MMM yyyy, HH:mm', 'Europe/Rome');
            String html =
                '<p>Dear Dr. ' + (lastName == null ? '' : lastName.escapeHtml4()) + ',</p>' +
                '<p>This is your copy of the consent you signed on ' + signedOn.escapeHtml4() +
                (String.isBlank(eventName) ? '' : ' at the <b>' + eventName.escapeHtml4() + '</b>') +
                (String.isBlank(repName) ? ' on our self-service kiosk' : ', collected by ' + repName.escapeHtml4()) + ':</p>' +
                '<p style="background:#fafafa;border-left:4px solid #0176d3;padding:10px 14px">' + text.body.escapeHtml4() +
                '<br/><small>Consent text ' + text.version.escapeHtml4() + '</small></p>' +
                (String.isBlank(slidesUrl)
                    ? ''
                    : '<p>As requested, here are the slides: <a href="' + slidesUrl.escapeHtml4() + '">download the slides</a></p>') +
                '<p>You can withdraw your consent at any time using the link in every email or by replying to this message.</p>';
            Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
            mail.setToAddresses(new List<String>{ toAddress });
            mail.setSubject('Your consent - copy for your records');
            mail.setHtmlBody(html);
            mail.setPlainTextBody(html.stripHtmlTags());
            mail.setSaveAsActivity(false);
            mail.setUseSignature(false);
            Id oweaId = orgWideAddressId();
            if (oweaId != null) {
                mail.setOrgWideEmailAddressId(oweaId);
            } else {
                String sender = ConsentCaptureConfig.settings().Email_Sender_Name__c;
                mail.setSenderDisplayName(String.isBlank(sender) ? 'Danone Events' : sender);
            }
            return outcome(Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ mail }, false));
        } catch (Exception e) {
            return failed(e.getMessage());
        }
    }
}
