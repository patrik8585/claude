import { LightningElement } from 'lwc';
import getContext from '@salesforce/apex/RepCaptureController.getContext';
import searchHcps from '@salesforce/apex/RepCaptureController.searchHcps';
import addKnownHcp from '@salesforce/apex/RepCaptureController.addKnownHcp';
import saveWalkIn from '@salesforce/apex/RepCaptureController.saveWalkIn';
import extractFromNotes from '@salesforce/apex/RepCaptureController.extractFromNotes';
import getMyCapturesToday from '@salesforce/apex/RepCaptureController.getMyCapturesToday';

const BADGE = {
    valid: { cls: 'sm-badge ok', short: 'Consent on file' },
    optout: { cls: 'sm-badge red', short: 'Opted out' },
    pending: { cls: 'sm-badge wait', short: 'Consent pending' },
    none: { cls: 'sm-badge wait', short: 'No consent' }
};

/**
 * Rep capture page: select event -> search HCP first -> consent status drives the
 * options (on file / none / opted out) -> walk-in with dictated notes -> my captures today.
 */
export default class RepCaptureHub extends LightningElement {
    ctx;
    screen = 'events';
    eventId;
    eventName;
    query = '';
    results = [];
    searched = false;
    searching = false;
    selected;
    method;
    signed = false;
    added = {};
    walk = {};
    extraction;
    extracting = false;
    listening = false;
    micHint;
    recognition;
    myCaps = [];
    saving = false;
    flash = false;
    notice;
    error;
    searchTimer;
    noticeTimer;

    connectedCallback() {
        this.load();
    }

    renderedCallback() {
        // textarea has no value attribute in LWC templates: keep it in sync with dictation / extraction
        const ta = this.template.querySelector('textarea');
        const notes = this.walk.notes || '';
        if (ta && ta.value !== notes) {
            ta.value = notes;
        }
    }

    disconnectedCallback() {
        this.stopMic();
        clearTimeout(this.searchTimer);
        clearTimeout(this.noticeTimer);
    }

    async load() {
        try {
            this.ctx = await getContext();
            this.refreshMyCaptures();
        } catch (e) {
            this.error = this.msg(e);
        }
    }

    // ---------------------------------------------------------------- getters: context

    get repName() {
        return this.ctx ? this.ctx.repName : '';
    }
    get initials() {
        return (this.repName || '')
            .split(' ')
            .map((p) => p.charAt(0))
            .join('')
            .slice(0, 2)
            .toUpperCase();
    }
    get events() {
        return this.ctx ? this.ctx.events : [];
    }
    get noEvents() {
        return this.ctx && this.ctx.events.length === 0;
    }
    get question() {
        return this.ctx ? this.ctx.consent.question : '';
    }
    get consentText() {
        return this.ctx ? this.ctx.consent.body : '';
    }

    get isEvents() {
        return this.screen === 'events';
    }
    get isCapture() {
        return this.screen === 'capture';
    }
    get isWalkIn() {
        return this.screen === 'walkin';
    }
    get isCaptures() {
        return this.screen === 'captures';
    }
    get showTabs() {
        return this.screen !== 'events';
    }
    get captureTabClass() {
        return this.screen === 'captures' ? '' : 'on';
    }
    get capturesTabClass() {
        return this.screen === 'captures' ? 'on' : '';
    }

    // ---------------------------------------------------------------- navigation

    selectEvent(evt) {
        const id = evt.currentTarget.dataset.id;
        const ev = this.events.find((x) => x.id === id);
        this.eventId = id;
        this.eventName = ev ? ev.name : '';
        this.screen = 'capture';
        this.resetSearch();
    }

    changeEvent() {
        this.screen = 'events';
    }

    showCapture() {
        this.screen = this.eventId ? 'capture' : 'events';
    }

    showCaptures() {
        this.stopMic();
        this.screen = 'captures';
        this.refreshMyCaptures();
    }

    backToResults() {
        this.selected = undefined;
        this.resetMethod();
    }

    backToSearch() {
        this.stopMic();
        this.screen = 'capture';
    }

    resetSearch() {
        this.query = '';
        this.results = [];
        this.searched = false;
        this.selected = undefined;
        this.resetMethod();
    }

    resetMethod() {
        this.method = undefined;
        this.signed = false;
    }

    // ---------------------------------------------------------------- search

    handleSearch(evt) {
        this.query = evt.target.value;
        this.selected = undefined;
        clearTimeout(this.searchTimer);
        if ((this.query || '').trim().length < 2) {
            this.results = [];
            this.searched = false;
            return;
        }
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.searchTimer = setTimeout(() => this.runSearch(), 300);
    }

    async runSearch() {
        this.searching = true;
        this.error = undefined;
        try {
            this.results = await searchHcps({ term: this.query, eventId: this.eventId });
            this.searched = true;
        } catch (e) {
            this.error = this.msg(e);
        } finally {
            this.searching = false;
        }
    }

    get resultRows() {
        return this.results.map((h) => {
            const b = BADGE[h.consentStatus] || BADGE.none;
            return { ...h, alreadyAdded: h.alreadyAdded || !!this.added[h.id], badgeClass: b.cls, badgeLabel: b.short };
        });
    }

    get showHint() {
        return !this.searched && !this.searching;
    }

    get showNotFound() {
        return this.searched && !this.searching && this.results.length === 0;
    }

    selectHcp(evt) {
        const id = evt.currentTarget.dataset.id;
        this.selected = this.results.find((h) => h.id === id);
        this.resetMethod();
    }

    get selectedHasConsent() {
        return this.selected && this.selected.consentStatus === 'valid';
    }
    get selectedOptedOut() {
        return this.selected && this.selected.consentStatus === 'optout';
    }
    get emailAllowed() {
        return !this.selectedOptedOut;
    }
    get selectedBadgeClass() {
        return (BADGE[this.selected.consentStatus] || BADGE.none).cls;
    }
    get selectedBadgeLabel() {
        const s = this.selected;
        if (s.consentStatus === 'valid') {
            return `Opt-in ${s.consentVersion || ''} · ${s.consentDate || ''}`;
        }
        if (s.consentStatus === 'optout') {
            return `Opted out · ${s.consentDate || ''}`;
        }
        if (s.consentStatus === 'pending') {
            return 'Pending confirmation';
        }
        return 'None on file';
    }
    get addedMessage() {
        return this.selected ? this.added[this.selected.id] : undefined;
    }

    // ---------------------------------------------------------------- consent options

    chooseMethod(evt) {
        this.method = evt.currentTarget.dataset.method;
        this.signed = false;
    }
    handleSigned() {
        this.signed = true;
    }
    handleCleared() {
        this.signed = false;
    }
    get isSign() {
        return this.method === 'sign';
    }
    methodClass(m) {
        const base = m === 'declined' ? 'btn dec' : 'btn';
        return this.method === m ? `${base} sel` : base;
    }
    get signClass() {
        return this.methodClass('sign');
    }
    get emailClass() {
        return this.methodClass('email');
    }
    get declinedClass() {
        return this.methodClass('declined');
    }
    get goDisabled() {
        return this.saving || !this.method || (this.method === 'sign' && !this.signed);
    }
    get goLabel() {
        switch (this.method) {
            case 'sign':
                return 'Confirm signature & add';
            case 'email':
                return 'Add & send confirmation link';
            case 'declined':
                return 'Add without communications';
            default:
                return 'Choose an option above';
        }
    }
    get walkGoLabel() {
        return this.method ? 'Save capture' : 'Choose a consent option above';
    }

    signatureDataUrl() {
        const pad = this.template.querySelector('c-signature-pad');
        return this.method === 'sign' && pad ? pad.getDataUrl() : null;
    }

    async addKnown() {
        const hcp = this.selected;
        this.saving = true;
        this.error = undefined;
        try {
            const r = await addKnownHcp({
                eventId: this.eventId,
                contactId: hcp.id,
                method: hcp.consentStatus === 'valid' ? null : this.method,
                signatureDataUrl: this.signatureDataUrl()
            });
            this.added = { ...this.added, [hcp.id]: r.message };
            this.toast('Added to event');
            this.refreshMyCaptures();
        } catch (e) {
            this.error = this.msg(e);
        } finally {
            this.saving = false;
        }
    }

    // ---------------------------------------------------------------- walk-in

    startWalkIn() {
        const q = (this.query || '').trim();
        const looksLikeEmail = q.includes('@');
        this.walk = looksLikeEmail ? { email: q } : { lastName: q.charAt(0).toUpperCase() + q.slice(1) };
        this.extraction = undefined;
        this.resetMethod();
        this.screen = 'walkin';
    }

    handleWalkInput(evt) {
        const field = evt.target.dataset.field;
        this.walk = { ...this.walk, [field]: evt.target.value };
    }

    get walkSpecialties() {
        const list = this.ctx ? this.ctx.specialties : [];
        return list.map((s) => ({ value: s, selected: s === this.walk.specialty }));
    }

    get walkClass() {
        return this.flash ? 'flash' : '';
    }

    get micClass() {
        return this.listening ? 'mic on' : 'mic';
    }

    toggleMic() {
        if (this.listening) {
            this.stopMic();
            return;
        }
        const Recognition = window.SpeechRecognition || window.webkitSpeechRecognition;
        if (!Recognition) {
            this.micHint = 'Voice input is not available in this browser: tap the textarea and use the microphone key of your phone keyboard.';
            const ta = this.template.querySelector('textarea');
            if (ta) {
                ta.focus();
            }
            return;
        }
        try {
            const rec = new Recognition();
            rec.lang = navigator.language || 'en-GB';
            rec.continuous = true;
            rec.interimResults = false;
            const startText = this.walk.notes ? this.walk.notes + ' ' : '';
            let spoken = '';
            rec.onresult = (event) => {
                for (let i = event.resultIndex; i < event.results.length; i++) {
                    if (event.results[i].isFinal) {
                        spoken += event.results[i][0].transcript + ' ';
                    }
                }
                this.walk = { ...this.walk, notes: (startText + spoken).trim() };
            };
            rec.onerror = (event) => {
                this.micHint = `Dictation stopped (${event.error}). You can also use the keyboard microphone.`;
                this.listening = false;
            };
            rec.onend = () => {
                this.listening = false;
            };
            rec.start();
            this.recognition = rec;
            this.listening = true;
            this.micHint = 'Listening… tap the microphone again to stop.';
        } catch (e) {
            this.micHint = 'Voice input could not start: use the microphone key of your keyboard.';
        }
    }

    stopMic() {
        if (this.recognition) {
            try {
                this.recognition.stop();
            } catch (e) {
                // already stopped
            }
            this.recognition = undefined;
        }
        this.listening = false;
    }

    get extractDisabled() {
        return this.extracting || !this.walk.notes;
    }

    get extractLabel() {
        return this.extracting ? 'Extracting…' : '✦ Extract with AI';
    }

    async extract() {
        this.stopMic();
        this.extracting = true;
        try {
            const r = await extractFromNotes({ notes: this.walk.notes });
            const w = { ...this.walk };
            ['firstName', 'lastName', 'email', 'specialty', 'city', 'organisation'].forEach((k) => {
                if (r[k]) {
                    w[k] = r[k];
                }
            });
            if (r.interest) {
                w.interest = r.interest;
            }
            this.walk = w;
            this.extraction = r;
            this.flash = true;
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            setTimeout(() => {
                this.flash = false;
            }, 1600);
        } catch (e) {
            this.error = this.msg(e);
        } finally {
            this.extracting = false;
        }
    }

    async saveWalkIn() {
        const w = this.walk;
        if (!w.firstName || !w.lastName) {
            this.error = 'First and last name are required.';
            return;
        }
        if (this.method === 'email' && !w.email) {
            this.error = 'Email needed to send the confirmation link.';
            return;
        }
        this.saving = true;
        this.error = undefined;
        try {
            const x = this.extraction;
            await saveWalkIn({
                eventId: this.eventId,
                data: {
                    firstName: w.firstName,
                    lastName: w.lastName,
                    email: w.email,
                    specialty: w.specialty,
                    city: w.city,
                    organisation: w.organisation,
                    notes: w.notes,
                    interest: w.interest,
                    createTask: !!x,
                    taskTitle: x ? x.taskTitle : null,
                    taskDueDate: x ? x.taskDueDate : null
                },
                method: this.method,
                signatureDataUrl: this.signatureDataUrl()
            });
            this.toast(x ? 'Capture saved · follow-up task created' : 'Capture saved');
            this.walk = {};
            this.extraction = undefined;
            this.resetMethod();
            this.resetSearch();
            this.screen = 'captures';
            this.refreshMyCaptures();
        } catch (e) {
            this.error = this.msg(e);
        } finally {
            this.saving = false;
        }
    }

    // ---------------------------------------------------------------- my captures

    async refreshMyCaptures() {
        try {
            const rows = await getMyCapturesToday();
            this.myCaps = rows.map((c) => ({ ...c, badgeClass: `sm-badge ${c.consentVariant}` }));
        } catch (e) {
            // not blocking
        }
    }

    get myCapsCount() {
        return this.myCaps.length;
    }

    get myConfirmed() {
        return this.myCaps.filter((c) => c.consentVariant === 'ok').length;
    }

    // ---------------------------------------------------------------- utils

    toast(text) {
        this.notice = text;
        clearTimeout(this.noticeTimer);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.noticeTimer = setTimeout(() => {
            this.notice = undefined;
        }, 2800);
    }

    msg(e) {
        return (e && e.body && e.body.message) || (e && e.message) || 'Unexpected error';
    }
}
