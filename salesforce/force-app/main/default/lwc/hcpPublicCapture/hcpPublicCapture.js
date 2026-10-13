import { LightningElement, api, wire } from 'lwc';
import { CurrentPageReference } from 'lightning/navigation';
import getFormContext from '@salesforce/apex/PublicCaptureController.getFormContext';
import submitCapture from '@salesforce/apex/PublicCaptureController.submitCapture';
import getConfirmation from '@salesforce/apex/PublicCaptureController.getConfirmation';
import confirmToken from '@salesforce/apex/PublicCaptureController.confirm';

const REQUIRED = ['firstName', 'lastName', 'email', 'specialty', 'city', 'consent'];
const EMAIL_RE = /^\S+@\S+\.\S+$/;
const KIOSK_RESET_SECONDS = 6;

/** Lightning app pages only keep c__-prefixed URL parameters: accept c__e / c__mode / c__t too. */
function normalize(state) {
    const out = {};
    Object.keys(state || {}).forEach((k) => {
        out[k.startsWith('c__') ? k.substring(3) : k] = state[k];
    });
    return out;
}

function emptyForm() {
    return { firstName: '', lastName: '', email: '', specialty: '', city: '', registrationNumber: '', consent: false, sendSlides: true, website: '' };
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
        if (invalid) {
            this.showErrors = true;
            this.formError = 'Please complete the highlighted fields.';
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
                    website: f.website
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
            this.form = emptyForm();
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
        this.showErrors = false;
        this.formError = undefined;
        this.view = 'form';
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
