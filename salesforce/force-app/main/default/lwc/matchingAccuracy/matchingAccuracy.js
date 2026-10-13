import { LightningElement } from 'lwc';
import getMetrics from '@salesforce/apex/MatchingAccuracyController.getMetrics';
import runGenerator from '@salesforce/apex/MatchingAccuracyController.runGenerator';

const CONFIRM = {
    generate: 'Deletes and recreates ~30 hospitals, ~1,000 HCPs and 150 test captures (mockup data is kept).',
    captures: 'Deletes the 150 test captures (and HCPs created from them) and creates them again: matching runs with the current parameters.',
    cleanup: 'Deletes every record created by the volume generator.'
};

/** Matching accuracy KPIs on the generated test captures, plus generator buttons. */
export default class MatchingAccuracy extends LightningElement {
    m = {};
    error;
    busy = false;
    confirmAction;
    timer;

    connectedCallback() {
        this.load();
    }

    disconnectedCallback() {
        clearTimeout(this.timer);
    }

    async load() {
        this.busy = true;
        try {
            this.m = await getMetrics();
            this.error = undefined;
            if (this.m.jobStatus && /^(Queued|Preparing|Processing|Holding)/.test(this.m.jobStatus)) {
                clearTimeout(this.timer);
                // eslint-disable-next-line @lwc/lwc/no-async-operation
                this.timer = setTimeout(() => this.load(), 8000);
            }
        } catch (e) {
            this.error = (e && e.body && e.body.message) || 'Unexpected error';
        } finally {
            this.busy = false;
        }
    }

    pct(v) {
        return v === null || v === undefined ? '—' : `${v}%`;
    }

    get hasData() {
        return this.m && this.m.total > 0;
    }
    get autoPrecision() {
        return this.pct(this.m.autoPrecision);
    }
    get reviewRate() {
        return this.pct(this.m.reviewRate);
    }
    get falseNewRate() {
        return this.pct(this.m.falseNewRate);
    }
    get reviewRecall() {
        return this.pct(this.m.reviewRecall);
    }
    get reviewTop1() {
        return this.pct(this.m.reviewTop1);
    }
    get outcomeAgreement() {
        return this.pct(this.m.outcomeAgreement);
    }
    get duplicateRecall() {
        return this.pct(this.m.duplicateRecall);
    }
    get duplicatePrecision() {
        return this.pct(this.m.duplicatePrecision);
    }

    get caseRows() {
        return (this.m.byCase || []).map((r) => ({ ...r, rowClass: r.asExpected < r.total ? 'off' : '' }));
    }

    get problemRows() {
        return (this.m.problems || []).map((p) => ({ ...p, url: `/lightning/r/Capture__c/${p.captureId}/view` }));
    }

    get hasProblems() {
        return this.problemRows.length > 0;
    }

    get problemCount() {
        return this.problemRows.length;
    }

    ask(evt) {
        this.confirmAction = evt.currentTarget.dataset.action;
    }

    get confirmText() {
        return CONFIRM[this.confirmAction];
    }

    cancel() {
        this.confirmAction = undefined;
    }

    async run() {
        const action = this.confirmAction;
        this.busy = true;
        try {
            await runGenerator({ action });
            this.confirmAction = undefined;
            this.m = { ...this.m, jobStatus: 'Queued' };
            clearTimeout(this.timer);
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            this.timer = setTimeout(() => this.load(), 5000);
        } catch (e) {
            this.error = (e && e.body && e.body.message) || 'Unexpected error';
        } finally {
            this.busy = false;
        }
    }
}
