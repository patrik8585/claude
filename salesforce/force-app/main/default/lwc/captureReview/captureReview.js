import { LightningElement, api } from 'lwc';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import getReviewData from '@salesforce/apex/CaptureReviewController.getReviewData';
import matchToContact from '@salesforce/apex/CaptureReviewController.matchToContact';
import createNewHcp from '@salesforce/apex/CaptureReviewController.createNewHcp';
import discardCapture from '@salesforce/apex/CaptureReviewController.discard';
import rerunMatching from '@salesforce/apex/CaptureReviewController.rerunMatching';

const PATH = ['Received', 'Auto-matching', 'To review', 'Matched', 'Consent created', 'Sent to Gigya'];
const STAGE_INDEX = {
    Received: 1,
    Error: 1,
    'To review': 2,
    Discarded: 3,
    Matched: 3,
    'Completed - no consent': 3,
    'Consent created': 4,
    'Sent to Gigya': 5
};
const FLAG_CLASS = { Exact: 'exact', Partial: 'partial', None: '', 'Not captured': 'na' };
const FLAG_MARK = { Exact: ' ✓', Partial: ' ≈' };

/**
 * Review console for Capture__c: path, captured data, AI-style suggestion,
 * side-by-side candidate comparison and Match / Create new HCP / Discard.
 */
export default class CaptureReview extends LightningElement {
    _recordId;
    connected = false;
    data;
    error;
    busy = false;
    selectedId;

    /** Record page Id, or the capture chosen in the Matching workbench (reloads on change). */
    @api
    get recordId() {
        return this._recordId;
    }
    set recordId(value) {
        const changed = value !== this._recordId;
        this._recordId = value;
        if (changed && this.connected) {
            this.selectedId = undefined;
            this.data = undefined;
            this.load();
        }
    }

    connectedCallback() {
        this.connected = true;
        this.load();
    }

    disconnectedCallback() {
        this.connected = false;
    }

    async load() {
        if (!this._recordId) {
            return;
        }
        try {
            this.data = await getReviewData({ captureId: this.recordId });
            const rec = this.data.candidates.find((c) => c.recommended);
            if (!this.selectedId && rec) {
                this.selectedId = rec.contactId;
            }
            this.error = undefined;
        } catch (e) {
            this.error = this.msg(e);
        }
    }

    get capture() {
        return this.data ? this.data.capture : {};
    }

    get capturedName() {
        const c = this.capture;
        return `${c.First_Name__c || ''} ${c.Last_Name__c || ''}`.trim();
    }

    get eventName() {
        return this.capture.Event__r ? this.capture.Event__r.Name : '';
    }

    get capturedBy() {
        return this.capture.Captured_By_Name__c || 'HCP (self-service)';
    }

    get optInLabel() {
        return this.capture.Opt_In_Status__c || '—';
    }

    get optInBadge() {
        const s = this.capture.Opt_In_Status__c;
        return s === 'Confirmed' ? 'badge auto' : s === 'Declined' ? 'badge red' : 'badge warn';
    }

    get pathSteps() {
        const stage = this.capture.Processing_Stage__c;
        const idx = STAGE_INDEX[stage] !== undefined ? STAGE_INDEX[stage] : 0;
        return PATH.map((label, i) => {
            let shown = label;
            if (stage === 'Discarded' && i === 3) {
                shown = 'Discarded';
            }
            if (stage === 'Completed - no consent' && i === 4) {
                shown = 'No consent (declined)';
            }
            let cls = '';
            if (i < idx) {
                cls = 'd';
            } else if (i === idx) {
                cls = stage === 'Discarded' || stage === 'Error' ? 'x' : 'c';
            }
            if (stage === 'Sent to Gigya' && i === idx) {
                cls = 'd';
            }
            return { label: (cls === 'd' ? '✓ ' : '') + shown, cls };
        });
    }

    get hasCandidates() {
        return this.data && this.data.candidates.length > 0;
    }

    get candidateCount() {
        return this.data.candidates.length;
    }

    get readOnly() {
        return !this.data.canReview;
    }

    get candidateHeaders() {
        return this.data.candidates.map((c) => ({
            ...c,
            selected: c.contactId === this.selectedId,
            thClass: c.contactId === this.selectedId ? 'sel' : '',
            scoreStyle: `width:${c.score}%`,
            url: `/lightning/r/Contact/${c.contactId}/view`
        }));
    }

    get rows() {
        const c = this.capture;
        const defs = [
            ['Name', this.capturedName, 'fullName', 'nameMatch'],
            ['Email', c.Email__c, 'email', 'emailMatch'],
            ['Specialty', c.Specialty__c, 'specialty', 'specialtyMatch'],
            ['City', c.City__c, 'city', 'cityMatch'],
            ['Hospital / department', this.capturedHco, 'affiliations', 'organisationMatch'],
            ['Reg. number', c.Registration_Number__c, 'registrationNumber', 'regMatch'],
            ['Why this score', '', 'explanationText', null]
        ];
        return defs.map(([label, captured, field, flagField]) => ({
            label,
            captured: captured || '—',
            cells: this.data.candidates.map((x) => ({
                key: `${x.contactId}-${field}`,
                value: (this.cellValue(x, field) || '—') + (flagField ? FLAG_MARK[x[flagField]] || '' : ''),
                cls: (flagField ? FLAG_CLASS[x[flagField]] || '' : 'why')
            }))
        }));
    }

    cellValue(x, field) {
        if (field === 'explanationText') {
            return (x.explanation || []).join('\n');
        }
        if (field === 'affiliations') {
            return x.affiliations || x.organisation;
        }
        return x[field];
    }

    get capturedHco() {
        const c = this.capture;
        const parts = [];
        if (c.Department__r) {
            parts.push(c.Department__r.Name);
        } else if (c.Hospital__r) {
            parts.push(c.Hospital__r.Name);
        }
        if (c.Organisation__c && !parts.some((p) => p.includes(c.Organisation__c))) {
            parts.push(`"${c.Organisation__c}"`);
        }
        return parts.join(' · ');
    }

    get selectedCandidate() {
        return this.data.candidates.find((c) => c.contactId === this.selectedId);
    }

    get matchLabel() {
        const s = this.selectedCandidate;
        return s ? `Match to ${s.fullName} (${s.city || '?'})` : 'Match';
    }

    get matchedUrl() {
        return this.capture.Matched_Contact__c ? `/lightning/r/Contact/${this.capture.Matched_Contact__c}/view` : null;
    }

    get consentUrl() {
        return this.capture.Consent__c ? `/lightning/r/Consent__c/${this.capture.Consent__c}/view` : null;
    }

    get resultMessage() {
        const c = this.capture;
        switch (c.Matching_Status__c) {
            case 'Reviewed - matched':
                return `Matched to ${this.data.matchedContactName} – ${c.Matched_By__c}. ${this.consentNote}`;
            case 'Reviewed - new HCP':
                return `New HCP created from this capture. ${this.consentNote}`;
            case 'Discarded':
                return 'Capture discarded. No HCP or consent record created.';
            case 'Auto-matched':
                return `Auto-matched (${c.Match_Rule__c}) to ${this.data.matchedContactName}. ${this.consentNote}`;
            case 'New HCP':
                return `No candidate found – new HCP ${this.data.matchedContactName} created. ${this.consentNote}`;
            case 'Queued':
                return 'Waiting for automatic matching (a few seconds). Refresh the page.';
            default:
                return null;
        }
    }

    get consentNote() {
        if (this.data.consentName) {
            return `Consent record ${this.data.consentName}.`;
        }
        if (this.capture.Opt_In_Status__c === 'Declined') {
            return 'HCP declined: no consent record.';
        }
        return '';
    }

    get resultClass() {
        return this.capture.Matching_Status__c === 'Discarded' || this.capture.Matching_Status__c === 'Queued' ? 'alert warn' : 'alert ok';
    }

    get canRerun() {
        return this.capture.Matching_Status__c === 'Error' || this.capture.Matching_Status__c === 'Queued';
    }

    pick(evt) {
        this.selectedId = evt.target.value;
    }

    selectRecommended() {
        const rec = this.data.candidates.find((c) => c.recommended);
        if (rec) {
            this.selectedId = rec.contactId;
        }
    }

    match() {
        if (!this.selectedId) {
            this.error = 'Select a candidate first.';
            return;
        }
        this.run(() => matchToContact({ captureId: this.recordId, contactId: this.selectedId }));
    }

    createNew() {
        this.run(() => createNewHcp({ captureId: this.recordId }));
    }

    discard() {
        this.run(() => discardCapture({ captureId: this.recordId }));
    }

    rerun() {
        this.run(() => rerunMatching({ captureId: this.recordId }));
    }

    async run(action) {
        this.busy = true;
        this.error = undefined;
        try {
            await action();
            await this.load();
            await notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
            this.dispatchEvent(new CustomEvent('resolved', { detail: { captureId: this.recordId } }));
        } catch (e) {
            this.error = this.msg(e);
        } finally {
            this.busy = false;
        }
    }

    msg(e) {
        return (e && e.body && e.body.message) || (e && e.message) || 'Unexpected error';
    }
}
