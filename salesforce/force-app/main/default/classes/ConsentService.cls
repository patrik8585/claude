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
        return base + (base.contains('?') ? '&' : '?') + 't=' + token;
    }

    /**
     * Sends the double opt-in email. Never throws: returns false when the link
     * cannot be built or the org email limit / deliverability blocks the send.
     */
    public static Boolean sendConfirmationEmail(String toAddress, String lastName, String eventName, String token) {
        String link = confirmationLink(token);
        if (String.isBlank(toAddress) || link == null) {
            return false;
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
            List<Messaging.SendEmailResult> results = Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ mail }, false);
            return !results.isEmpty() && results[0].isSuccess();
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Confirmation email not sent: ' + e.getMessage());
            return false;
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
            update updates;
        }
    }

    // ------------------------------------------------------------ signature

    /** Stores a PNG data URL (from the signature canvas) as a file on the capture. */
    public static Id saveSignature(Id captureId, String captureName, String dataUrl) {
        if (String.isBlank(dataUrl)) {
            return null;
        }
        String b64 = dataUrl.contains(',') ? dataUrl.substringAfter(',') : dataUrl;
        if (b64.length() > 2000000) {
            throw new IllegalArgumentException('Signature image too large.');
        }
        ContentVersion cv = new ContentVersion(
            Title = 'Consent signature - ' + captureName,
            PathOnClient = 'signature.png',
            VersionData = EncodingUtil.base64Decode(b64),
            FirstPublishLocationId = captureId
        );
        insert cv;
        return cv.Id;
    }
}
