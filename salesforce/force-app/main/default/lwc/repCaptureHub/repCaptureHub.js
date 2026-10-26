import { LightningElement } from 'lwc';
import getContext from '@salesforce/apex/RepCaptureController.getContext';
import searchHcps from '@salesforce/apex/RepCaptureController.searchHcps';
import addKnownHcp from '@salesforce/apex/RepCaptureController.addKnownHcp';
import saveWalkIn from '@salesforce/apex/RepCaptureController.saveWalkIn';
import getMyCapturesToday from '@salesforce/apex/RepCaptureController.getMyCapturesToday';
import getRegisteredAttendees from '@salesforce/apex/RepCaptureController.getRegisteredAttendees';

const MIC_ERRORS = {
    'not-allowed': 'Microphone blocked: allow microphone access for this site (browser address bar › site settings), or use the microphone key of your keyboard.',
    'service-not-allowed': 'The browser does not allow speech recognition here: use the microphone key of your keyboard.',
    'audio-capture': 'No microphone found: check the device, or type the notes.',
    network: 'Dictation needs a connection to the browser speech service: check the network, or use the keyboard microphone (works offline on most phones).',
    'language-not-supported': 'This language is not supported by the browser dictation: switch IT/EN or use the keyboard microphone.'
};
const MAX_RESTARTS = 5;
/** The rep works a whole day at one congress: the chosen congress is remembered on the device. */
const EVENT_KEY = 'hcpRepHub.eventId';

/** Walk-in form with every field empty (an undefined value would show as "undefined" in the inputs). */
function emptyWalk(values) {
    return { firstName: '', lastName: '', email: '', specialty: '', city: '', notes: '', ...values };
}
const ATTENDANCE = {
    registered: { cls: 'sm-badge reg', short: 'Registered' },
    attended: { cls: 'sm-badge ok', short: 'Checked in' }
};

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
    registeredList = { registered: 0, checkedIn: 0, attendees: [] };
    showRegistered = false;
    searched = false;
    searching = false;
    selected;
    method;
    signed = false;
    added = {};
    /** Therapeutic areas ticked for the current HCP (optional, several allowed). */
    areas = [];
    areasOpen = false;
    walk = emptyWalk();
    listening = false;
    micHint;
    recognition;
    myCaps = [];
    saving = false;
    notice;
    error;
    searchTimer;
    noticeTimer;
    interimText = '';
    dictationLang = (navigator.language || '').toLowerCase().startsWith('it') ? 'it-IT' : 'en-GB';
    userStopped = false;
    restarts = 0;
    dictationBase = '';
    dictated = '';

    connectedCallback() {
        this.load();
    }

    renderedCallback() {
        // textarea has no value attribute in LWC templates: keep it in sync with dictation
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
            this.restoreEvent();
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
        this.openEvent(evt.currentTarget.dataset.id);
    }

    openEvent(id) {
        const ev = this.events.find((x) => x.id === id);
        if (!ev) {
            return;
        }
        this.eventId = id;
        this.eventName = ev.name;
        this.screen = 'capture';
        this.resetSearch();
        this.showRegistered = false;
        this.loadRegistered();
        try {
            localStorage.setItem(EVENT_KEY, id);
        } catch (e) {
            // storage not available: the rep chooses the congress again next time
        }
    }

    /** Back on the congress chosen last time on this device, or on the only active congress. */
    restoreEvent() {
        let saved;
        try {
            saved = localStorage.getItem(EVENT_KEY);
        } catch (e) {
            saved = null;
        }
        if (saved && this.events.some((x) => x.id === saved)) {
            this.openEvent(saved);
        } else if (this.events.length === 1) {
            this.openEvent(this.events[0].id);
        }
    }

    /** Ready for the next HCP at the same congress: empty search, focus on the search box. */
    nextHcp() {
        this.stopMic();
        this.walk = emptyWalk();
        this.resetSearch();
        this.showRegistered = false;
        this.screen = 'capture';
        this.loadRegistered();
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        requestAnimationFrame(() => {
            const q = this.template.querySelector('[data-search]');
            if (q) {
                q.focus();
            }
        });
    }

    async loadRegistered() {
        try {
            this.registeredList = await getRegisteredAttendees({ eventId: this.eventId });
        } catch (e) {
            this.registeredList = { registered: 0, checkedIn: 0, attendees: [] };
        }
    }

    toggleRegistered() {
        this.showRegistered = !this.showRegistered;
        this.selected = undefined;
        this.resetMethod();
        if (this.showRegistered) {
            this.query = '';
            this.searched = false;
            this.results = [];
            this.loadRegistered();
        }
    }

    get hasRegistered() {
        return this.registeredList && this.registeredList.registered > 0;
    }
    get registeredSummary() {
        const r = this.registeredList;
        return `${r.registered} registered · ${r.checkedIn} checked in`;
    }
    get registeredToggleLabel() {
        return this.showRegistered ? 'Back to search' : 'Show registered list';
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
        this.areas = [];
        this.areasOpen = false;
    }

    // ---------------------------------------------------------------- search

    handleSearch(evt) {
        this.query = evt.target.value;
        this.selected = undefined;
        this.showRegistered = false;
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

    get visibleResults() {
        return this.showRegistered ? this.registeredList.attendees || [] : this.results;
    }

    get resultRows() {
        return this.visibleResults.map((h) => {
            const b = BADGE[h.consentStatus] || BADGE.none;
            const attendance = this.added[h.id] && h.attendance === 'registered' ? 'attended' : h.attendance;
            const a = ATTENDANCE[attendance];
            return {
                ...h,
                alreadyAdded: h.alreadyAdded || !!this.added[h.id],
                badgeClass: b.cls,
                badgeLabel: b.short,
                attendanceClass: a ? a.cls : undefined,
                attendanceLabel: a ? a.short : undefined,
                otherTerritory: h.inMyTerritory === false,
                hcoLine: [h.department, h.organisation].filter((x) => !!x).join(' · ')
            };
        });
    }

    get showHint() {
        return !this.searched && !this.searching && !this.showRegistered;
    }

    get showWalkInLink() {
        return this.searched && !this.searching && this.results.length > 0;
    }

    get showNotFound() {
        return this.searched && !this.searching && this.results.length === 0;
    }

    selectHcp(evt) {
        const id = evt.currentTarget.dataset.id;
        this.selected = this.visibleResults.find((h) => h.id === id);
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
    get selectedOtherAffiliations() {
        const a = this.selected && this.selected.affiliations;
        if (!a) {
            return undefined;
        }
        const others = a.split('; ').filter((x) => !x.endsWith('(primary)'));
        return others.length ? others.join('; ') : undefined;
    }
    get selectedRegistered() {
        return this.selected && this.selected.attendance === 'registered';
    }
    get addKnownLabel() {
        return this.selectedRegistered ? '✓ Check in' : '+ Add to event';
    }
    /** Before the capture only: once it is saved the card offers "New search – next HCP" instead. */
    get showBackToResults() {
        return !this.addedMessage;
    }

    get addedTitle() {
        return this.selectedRegistered ? 'Checked in.' : 'Added to event.';
    }
    get addedMessage() {
        return this.selected ? this.added[this.selected.id] : undefined;
    }

    // ---------------------------------------------------------------- therapeutic area

    toggleAreas() {
        this.areasOpen = !this.areasOpen;
    }
    toggleArea(evt) {
        const v = evt.currentTarget.dataset.value;
        this.areas = this.areas.includes(v) ? this.areas.filter((x) => x !== v) : [...this.areas, v];
    }
    get areasExpanded() {
        return this.areasOpen ? 'true' : 'false';
    }
    get areaOptions() {
        const list = this.ctx ? this.ctx.therapeuticAreas || [] : [];
        return list.map((value) => {
            const on = this.areas.includes(value);
            return { value, pressed: on ? 'true' : 'false', cls: on ? 'chip on' : 'chip' };
        });
    }
    get areasSummary() {
        const n = this.areas.length;
        if (n === 0) {
            return this.areasOpen ? '▴' : 'Choose ▾';
        }
        const text = n <= 2 ? this.areas.join(', ') : `${n} selected`;
        return `${text} ${this.areasOpen ? '▴' : '▾'}`;
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
        const verb = this.selectedRegistered ? 'check in' : 'add';
        switch (this.method) {
            case 'sign':
                return `Confirm signature & ${verb}`;
            case 'email':
                return this.selectedRegistered ? 'Check in & send confirmation link' : 'Add & send confirmation link';
            case 'declined':
                return this.selectedRegistered ? 'Check in without new consent' : 'Add without communications';
            default:
                return 'Choose an option above';
        }
    }
    get walkGoLabel() {
        return this.method ? 'Save capture' : 'Choose a consent option above';
    }

    deviceInfo() {
        try {
            return `${navigator.userAgent} | screen ${window.screen.width}x${window.screen.height}`;
        } catch (e) {
            return null;
        }
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
                signatureDataUrl: this.signatureDataUrl(),
                deviceInfo: this.deviceInfo(),
                therapeuticAreas: this.areas
            });
            this.added = { ...this.added, [hcp.id]: r.message };
            this.toast(hcp.attendance === 'registered' ? 'Checked in' : 'Added to event');
            if (hcp.attendance === 'registered') {
                this.registeredList = { ...this.registeredList, checkedIn: this.registeredList.checkedIn + 1 };
            }
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
        this.walk = emptyWalk(looksLikeEmail ? { email: q } : { lastName: q.charAt(0).toUpperCase() + q.slice(1) });
        this.resetMethod();
        this.screen = 'walkin';
    }

    handleWalkInput(evt) {
        const field = evt.target.dataset.field;
        this.walk = { ...this.walk, [field]: evt.target.value };
        if (field === 'notes' && this.listening) {
            // the rep edited the text while dictating: continue from what is now in the box
            this.dictationBase = evt.target.value ? evt.target.value + ' ' : '';
            this.dictated = '';
        }
    }

    get walkSpecialties() {
        const list = this.ctx ? this.ctx.specialties : [];
        return list.map((s) => ({ value: s, selected: s === this.walk.specialty }));
    }

    get micClass() {
        return this.listening ? 'mic on' : 'mic';
    }

    get listeningLabel() {
        return this.listening ? 'true' : 'false';
    }

    get langLabel() {
        return this.dictationLang === 'it-IT' ? 'IT' : 'EN';
    }

    toggleLang() {
        this.dictationLang = this.dictationLang === 'it-IT' ? 'en-GB' : 'it-IT';
    }

    /** Web Speech API constructor, or null (not supported, insecure context, or blocked by Lightning Web Security). */
    recognitionCtor() {
        try {
            if (window.isSecureContext === false) {
                return null;
            }
            return window.SpeechRecognition || window.webkitSpeechRecognition || null;
        } catch (e) {
            return null;
        }
    }

    toggleMic() {
        if (this.listening) {
            this.stopMic();
            this.micHint = undefined;
            return;
        }
        const Recognition = this.recognitionCtor();
        if (!Recognition) {
            this.micHint = 'Voice input is not available in this browser: tap the textarea and use the microphone key of your phone keyboard.';
            this.focusNotes();
            return;
        }
        this.userStopped = false;
        this.restarts = 0;
        this.dictationBase = this.walk.notes ? this.walk.notes + ' ' : '';
        this.dictated = '';
        this.startRecognition(Recognition);
    }

    startRecognition(Recognition) {
        let rec;
        try {
            rec = new Recognition();
            rec.lang = this.dictationLang;
            rec.continuous = true;
            rec.interimResults = true;
            rec.maxAlternatives = 1;
        } catch (e) {
            this.micHint = 'Voice input could not start: use the microphone key of your keyboard.';
            this.focusNotes();
            return;
        }
        rec.onresult = (event) => {
            let interim = '';
            for (let i = event.resultIndex; i < event.results.length; i++) {
                const text = event.results[i][0].transcript;
                if (event.results[i].isFinal) {
                    this.dictated += text.trim() + ' ';
                } else {
                    interim += text;
                }
            }
            this.walk = { ...this.walk, notes: (this.dictationBase + this.dictated).trim() };
            this.interimText = interim.trim();
        };
        rec.onerror = (event) => {
            const code = event && event.error;
            if (code === 'no-speech' || code === 'aborted') {
                return; // silence: onend restarts
            }
            this.userStopped = true;
            this.micHint = MIC_ERRORS[code] || `Dictation stopped (${code}). You can also use the keyboard microphone.`;
        };
        rec.onend = () => {
            this.interimText = '';
            // browsers end a "continuous" session after a pause: restart until the rep stops it
            if (!this.userStopped && this.restarts < MAX_RESTARTS) {
                this.restarts++;
                try {
                    rec.start();
                    return;
                } catch (e) {
                    // fall through: stop
                }
            }
            this.listening = false;
            this.recognition = undefined;
            if (!this.userStopped && this.restarts >= MAX_RESTARTS) {
                this.micHint = 'Dictation paused. Tap the microphone to continue.';
            }
        };
        try {
            rec.start();
            this.recognition = rec;
            this.listening = true;
            this.micHint = `Listening (${this.langLabel})… tap the microphone again to stop.`;
        } catch (e) {
            this.micHint = 'Voice input could not start: use the microphone key of your keyboard.';
            this.focusNotes();
        }
    }

    focusNotes() {
        const ta = this.template.querySelector('textarea');
        if (ta) {
            ta.focus();
        }
    }

    stopMic() {
        this.userStopped = true;
        if (this.recognition) {
            try {
                this.recognition.stop();
            } catch (e) {
                // already stopped
            }
            this.recognition = undefined;
        }
        this.listening = false;
        this.interimText = '';
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
            await saveWalkIn({
                eventId: this.eventId,
                data: {
                    firstName: w.firstName,
                    lastName: w.lastName,
                    email: w.email,
                    specialty: w.specialty,
                    city: w.city,
                    notes: w.notes,
                    therapeuticAreas: this.areas
                },
                method: this.method,
                signatureDataUrl: this.signatureDataUrl(),
                deviceInfo: this.deviceInfo()
            });
            this.toast(`Capture saved: Dr. ${w.firstName} ${w.lastName}. Next HCP.`);
            this.resetMethod();
            this.nextHcp();
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
