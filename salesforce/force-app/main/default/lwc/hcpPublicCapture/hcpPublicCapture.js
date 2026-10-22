import { LightningElement, api, wire } from 'lwc';
import { CurrentPageReference } from 'lightning/navigation';
import getFormContext from '@salesforce/apex/PublicCaptureController.getFormContext';
import submitCapture from '@salesforce/apex/PublicCaptureController.submitCapture';
import getConfirmation from '@salesforce/apex/PublicCaptureController.getConfirmation';
import confirmToken from '@salesforce/apex/PublicCaptureController.confirm';

const REQUIRED = ['firstName', 'lastName', 'email', 'specialty', 'city', 'consent'];
const EMAIL_RE = /^\S+@\S+\.\S+$/;
const KIOSK_RESET_SECONDS = 6;
/** Kiosk: shared tablet, so the browser must not suggest what the previous visitor typed. */
const AUTOCOMPLETE_FORM = { firstName: 'given-name', lastName: 'family-name', email: 'email', city: 'address-level2', other: 'off' };
const AUTOCOMPLETE_KIOSK = { firstName: 'off', lastName: 'off', email: 'off', city: 'off', other: 'off' };

/** Lightning app pages only keep c__-prefixed URL parameters: accept c__e / c__mode / c__t too. */
function normalize(state) {
    const out = {};
    Object.keys(state || {}).forEach((k) => {
        out[k.startsWith('c__') ? k.substring(3) : k] = state[k];
    });
    return out;
}

function emptyForm() {
    return {
        firstName: '',
        lastName: '',
        email: '',
        specialty: '',
        city: '',
        registrationNumber: '',
        consent: false,
        sendSlides: true,
        website: '',
        confirmMethod: 'email'
    };
}

/**
 * Public HCP capture page (Experience Cloud, guest user).
 * URL parameters: ?e=<EventId>&ch=qr  |  ?e=<EventId>&mode=kiosk  |  ?t=<confirmation token>
 */
export default class HcpPublicCapture extends LightningElement {
    /** Fallback event Id when the URL has no ?e= (set in Experience Builder). */
    @api eventId;
    /** form | kiosk (URL ?mode=kiosk wins). */
    @api defaultMode = 'form';

    view = 'loading';
    ctx = {};
    form = emptyForm();
    showErrors = false;
    formError;
    fatalError;
    submitting = false;
    formToken;
    thanksName;
    thanksEmail;
    thanksSigned = false;
    thanksCopySent = false;
    hasSignature = false;
    countdown = 0;
    conf = {};
    params = {};
    started = false;
    timer;

    @wire(CurrentPageReference)
    wiredPage(ref) {
        if (ref && ref.state) {
            this.params = { ...this.params, ...normalize(ref.state) };
        }
        this.start();
    }

    connectedCallback() {
        try {
            const search = new URLSearchParams(window.location.search);
            const fromUrl = {};
            search.forEach((value, key) => {
                fromUrl[key] = value;
            });
            this.params = { ...normalize(fromUrl), ...this.params };
        } catch (e) {
            // window.location may be unavailable in some containers; rely on CurrentPageReference
        }
        // give the page reference wire a tick to arrive
        Promise.resolve().then(() => {
            this.start();
            if (!this.started) {
                this.fatalError = 'No event selected: open this page with ?e=<Event Id> (QR) or ?e=<Event Id>&mode=kiosk.';
                this.view = 'error';
            }
        });
    }

    disconnectedCallback() {
        this.stopTimer();
    }

    start() {
        if (this.started) {
            return;
        }
        if (this.params.t) {
            this.started = true;
            this.loadConfirmation();
            return;
        }
        if (!this.resolvedEventId) {
            return;
        }
        this.started = true;
        this.loadForm();
    }

    get resolvedEventId() {
        return this.params.e || this.eventId;
    }

    get isKiosk() {
        const mode = this.params.mode || this.defaultMode;
        return mode === 'kiosk' && this.view !== 'confirm';
    }

    // ---------------------------------------------------------------- loading

    async loadForm() {
        this.view = 'loading';
        this.fatalError = undefined;
        try {
            this.ctx = await getFormContext({ eventId: this.resolvedEventId });
            this.formToken = this.ctx.formToken;
            this.view = 'form';
        } catch (e) {
            this.fatalError = this.message(e, 'This registration page is not available.');
            this.view = 'error';
        }
    }

    async loadConfirmation() {
        this.view = 'loading';
        this.fatalError = undefined;
        try {
            this.conf = await getConfirmation({ token: this.params.t });
            this.view = 'confirm';
        } catch (e) {
            this.fatalError = this.message(e, 'This link is not valid.');
            this.view = 'error';
        }
    }

    // ---------------------------------------------------------------- form

    handleInput(evt) {
        const field = evt.target.dataset.field;
        const value = evt.target.type === 'checkbox' ? evt.target.checked : evt.target.value;
        this.form = { ...this.form, [field]: value };
    }

    get filledCount() {
        return REQUIRED.filter((k) => !!this.form[k]).length;
    }

    get progressLabel() {
        return `${this.filledCount} of ${REQUIRED.length} done`;
    }

    get progressStyle() {
        return `width:${Math.round((this.filledCount / REQUIRED.length) * 100)}%`;
    }

    get specialtyOptions() {
        return (this.ctx.specialties || []).map((s) => ({ value: s, selected: s === this.form.specialty }));
    }

    fieldClass(key) {
        const bad = this.showErrors && (!this.form[key] || (key === 'email' && !EMAIL_RE.test(this.form.email)));
        return bad ? 'in err' : 'in';
    }

    get cls() {
        return {
            firstName: this.fieldClass('firstName'),
            lastName: this.fieldClass('lastName'),
            email: this.fieldClass('email'),
            specialty: this.fieldClass('specialty'),
            city: this.fieldClass('city')
        };
    }

    get ac() {
        return this.isKiosk ? AUTOCOMPLETE_KIOSK : AUTOCOMPLETE_FORM;
    }

    // ---------------------------------------------------------------- kiosk signature

    handleMethod(evt) {
        const method = evt.currentTarget.dataset.method;
        if (method !== this.form.confirmMethod) {
            this.form = { ...this.form, confirmMethod: method };
            this.hasSignature = false;
        }
    }

    handleSigned() {
        this.hasSignature = true;
    }

    handleCleared() {
        this.hasSignature = false;
    }

    get isSignMethod() {
        return this.isKiosk && this.form.confirmMethod === 'sign';
    }
    get isEmailMethodLabel() {
        return this.isSignMethod ? 'false' : 'true';
    }
    get isSignMethodLabel() {
        return this.isSignMethod ? 'true' : 'false';
    }
    get emailOptClass() {
        return this.isSignMethod ? 'mopt' : 'mopt on';
    }
    get signOptClass() {
        return this.isSignMethod ? 'mopt on' : 'mopt';
    }
    get sigClass() {
        return this.showErrors && !this.hasSignature ? 'sig err' : 'sig';
    }
    get consentNote() {
        return this.isSignMethod ? 'signed on this screen' : 'no signature needed';
    }
    get thanksCopyText() {
        return this.thanksCopySent ? 'A copy has been sent to your email.' : 'Ask a Danone representative if you need a copy.';
    }

    signatureDataUrl() {
        const pad = this.template.querySelector('c-signature-pad');
        return this.isSignMethod && pad ? pad.getDataUrl() : null;
    }

    deviceInfo() {
        try {
            return `${navigator.userAgent} | screen ${window.screen.width}x${window.screen.height}`;
        } catch (e) {
            return null;
        }
    }

    get consentClass() {
        return this.showErrors && !this.form.consent ? 'chk err' : 'chk';
    }

    get submitLabel() {
        if (this.submitting) {
            return 'Sending…';
        }
        return this.isKiosk ? 'Register →' : 'Send me the slides →';
    }

    async handleSubmit() {
        const f = this.form;
        const invalid = REQUIRED.some((k) => !f[k]) || !EMAIL_RE.test(f.email || '');
        const signatureUrl = this.signatureDataUrl();
        const missingSignature = this.isSignMethod && !signatureUrl;
        if (invalid || missingSignature) {
            this.showErrors = true;
            this.formError = invalid ? 'Please complete the highlighted fields.' : 'Please sign in the box, or choose "Confirm by email".';
            return;
        }
        this.submitting = true;
        this.formError = undefined;
        try {
            const result = await submitCapture({
                eventId: this.resolvedEventId,
                mode: this.isKiosk ? 'kiosk' : 'qr',
                formToken: this.formToken,
                submission: {
                    firstName: f.firstName,
                    lastName: f.lastName,
                    email: f.email,
                    specialty: f.specialty,
                    city: f.city,
                    registrationNumber: f.registrationNumber,
                    consent: f.consent,
                    sendSlides: f.sendSlides,
                    website: f.website,
                    signatureDataUrl: signatureUrl,
                    deviceInfo: this.isKiosk ? this.deviceInfo() : null
                }
            });
            if (result.nextFormToken) {
                this.formToken = result.nextFormToken;
            }
            if (!result.success) {
                this.formError = result.message;
                return;
            }
            this.thanksName = result.firstName;
            this.thanksEmail = result.email;
            this.thanksSigned = result.signed === true;
            this.thanksCopySent = result.copySent === true;
            this.form = emptyForm();
            this.hasSignature = false;
            this.showErrors = false;
            this.view = 'thanks';
            if (this.isKiosk) {
                this.startCountdown();
            }
        } catch (e) {
            this.formError = this.message(e, 'Sorry, something went wrong. Please try again.');
        } finally {
            this.submitting = false;
        }
    }

    startCountdown() {
        this.stopTimer();
        this.countdown = KIOSK_RESET_SECONDS;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.timer = setInterval(() => {
            this.countdown -= 1;
            if (this.countdown <= 0) {
                this.resetKiosk();
            }
        }, 1000);
    }

    stopTimer() {
        if (this.timer) {
            clearInterval(this.timer);
            this.timer = undefined;
        }
    }

    resetKiosk() {
        this.stopTimer();
        this.form = emptyForm();
        this.hasSignature = false;
        this.thanksSigned = false;
        this.thanksCopySent = false;
        this.thanksName = undefined;
        this.thanksEmail = undefined;
        this.showErrors = false;
        this.formError = undefined;
        this.view = 'form';
        // hide the on-screen keyboard and its suggestion bar from the previous visitor
        const focused = this.template.activeElement;
        if (focused && focused.blur) {
            focused.blur();
        }
        window.scrollTo(0, 0);
    }

    // ---------------------------------------------------------------- confirmation

    async handleConfirm() {
        this.submitting = true;
        try {
            this.conf = await confirmToken({ token: this.params.t });
        } catch (e) {
            this.fatalError = this.message(e, 'Sorry, we could not confirm your email.');
            this.view = 'error';
        } finally {
            this.submitting = false;
        }
    }

    // ---------------------------------------------------------------- view helpers

    get loading() {
        return this.view === 'loading';
    }
    get isForm() {
        return this.view === 'form';
    }
    get isThanks() {
        return this.view === 'thanks';
    }
    get isConfirmValid() {
        return this.view === 'confirm' && this.conf.status === 'valid';
    }
    get isConfirmed() {
        return this.view === 'confirm' && this.conf.status === 'confirmed';
    }
    get isConfirmExpired() {
        return this.view === 'confirm' && this.conf.status === 'expired';
    }
    get isConfirmInvalid() {
        return this.view === 'confirm' && this.conf.status === 'invalid';
    }
    get showHeader() {
        return !this.isKiosk;
    }
    get headerTitle() {
        if (this.view === 'confirm') {
            return this.conf.eventName || 'Danone';
        }
        return this.view === 'thanks' ? this.ctx.eventShortName : this.ctx.eventName;
    }
    get rootClass() {
        return this.isKiosk ? 'root kiosk' : 'root';
    }
    get gridClass() {
        return this.isKiosk ? 'kgrid' : '';
    }

    message(e, fallback) {
        return (e && e.body && e.body.message) || fallback;
    }
}
