import { LightningElement } from 'lwc';
import getMetrics from '@salesforce/apex/MatchingAccuracyController.getMetrics';
import getEventMetrics from '@salesforce/apex/MatchingAccuracyController.getEventMetrics';
import getEventOptions from '@salesforce/apex/MatchingAccuracyController.getEventOptions';

const TEST = 'TEST';
const REFRESH_MS = 15000;

function pct(v) {
    return v === null || v === undefined ? '—' : `${v}%`;
}

function duration(minutes) {
    if (minutes === null || minutes === undefined) {
        return null;
    }
    if (minutes < 60) {
        return `${minutes} min`;
    }
    if (minutes < 48 * 60) {
        return `${Math.round(minutes / 6) / 10} h`;
    }
    return `${Math.round(minutes / 144) / 10} days`;
}

/**
 * Matching figures per congress (live, from the real captures) and, for the synthetic test set,
 * precision against the expected outcome. Refreshes every 15 seconds while the page is visible.
 */
export default class MatchingAccuracy extends LightningElement {
    view = '';
    options = [];
    e = {};
    m = {};
    error;
    busy = false;
    timer;

    connectedCallback() {
        this.refresh();
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.timer = setInterval(() => {
            if (document.visibilityState === 'visible') {
                this.refresh(true);
            }
        }, REFRESH_MS);
    }

    disconnectedCallback() {
        clearInterval(this.timer);
    }

    async loadOptions() {
        try {
            this.options = await getEventOptions();
        } catch (err) {
            this.error = this.msg(err);
        }
    }

    async refresh(silent) {
        if (silent !== true) {
            this.busy = true;
        }
        try {
            // the congress list is reloaded too, so a congress created during the demo appears
            this.loadOptions();
            if (this.view === TEST) {
                this.m = await getMetrics();
            } else {
                this.e = await getEventMetrics({ eventId: this.view || null });
            }
            this.error = undefined;
        } catch (err) {
            this.error = this.msg(err);
        } finally {
            this.busy = false;
        }
    }

    changeView(evt) {
        this.view = evt.target.value;
        this.refresh();
    }

    openEventRow(evt) {
        evt.preventDefault();
        this.view = evt.currentTarget.dataset.id;
        this.refresh();
    }

    // ---------------------------------------------------------------- selector

    get eventOptions() {
        return this.options.map((o) => ({ ...o, label: `${o.label} (${o.captures})`, selected: o.value === this.view }));
    }
    get allSelected() {
        return this.view === '';
    }
    get testSelected() {
        return this.view === TEST;
    }
    get isEventView() {
        return this.view !== TEST;
    }
    get viewNote() {
        if (this.view === TEST) {
            return 'Precision against the expected outcome of the generated test captures (script 05; 07 regenerates them after a parameter change). A match to a known duplicate record of the expected HCP counts as correct.';
        }
        const at = this.e && this.e.refreshedAt ? ` Updated ${this.e.refreshedAt}.` : '';
        return `Live figures from the captures of ${this.view ? 'this congress' : 'all congresses'}, refreshed every ${REFRESH_MS / 1000} seconds.${at}`;
    }

    // ---------------------------------------------------------------- congress figures

    get hasEventData() {
        return this.e && this.e.total > 0;
    }
    get channelText() {
        return (this.e.byChannel || []).map((c) => `${c.label} ${c.count}`).join(' · ');
    }
    get autoRate() {
        return pct(this.e.autoRate);
    }
    get reviewRate() {
        return pct(this.e.reviewRate);
    }
    get acceptedRate() {
        return pct(this.e.recommendationAcceptedRate);
    }
    get avgTopScore() {
        return this.e.avgTopScore === null || this.e.avgTopScore === undefined ? '—' : this.e.avgTopScore;
    }
    get reviewedTotal() {
        return (this.e.reviewedMatched || 0) + (this.e.reviewedNew || 0) + (this.e.reviewedDiscarded || 0);
    }
    get backlogClass() {
        return this.e.backlog > 0 ? 'warn' : 'ok';
    }
    get oldestText() {
        const d = duration(this.e.oldestWaitingMinutes);
        return d ? `oldest waiting ${d}` : 'nothing waiting';
    }
    get avgReviewText() {
        const d = duration(this.e.avgReviewMinutes);
        return d ? `avg. ${d} to decide` : 'no decision yet';
    }
    get hasByEvent() {
        return !this.view && this.e.byEvent && this.e.byEvent.length > 0;
    }
    get eventRows() {
        return (this.e.byEvent || [])
            .map((r) => ({
                ...r,
                autoRateText: r.autoRate === null || r.autoRate === undefined ? '' : `(${r.autoRate}%)`,
                reviewRateText: r.reviewRate === null || r.reviewRate === undefined ? '' : `(${r.reviewRate}%)`,
                reviewedTotal: r.reviewedMatched + r.reviewedNew + r.reviewedDiscarded,
                acceptedText: r.reviewedMatched ? `${r.recommendationAccepted} / ${r.reviewedMatched}` : '—',
                backlogClass: r.backlog > 0 ? 'warn' : ''
            }))
            .sort((a, b) => b.total - a.total);
    }

    // ---------------------------------------------------------------- test set

    get hasData() {
        return this.m && this.m.total > 0;
    }
    get autoPrecision() {
        return pct(this.m.autoPrecision);
    }
    get testReviewRate() {
        return pct(this.m.reviewRate);
    }
    get falseNewRate() {
        return pct(this.m.falseNewRate);
    }
    get reviewRecall() {
        return pct(this.m.reviewRecall);
    }
    get reviewTop1() {
        return pct(this.m.reviewTop1);
    }
    get outcomeAgreement() {
        return pct(this.m.outcomeAgreement);
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

    msg(err) {
        return (err && err.body && err.body.message) || 'Unexpected error';
    }
}
