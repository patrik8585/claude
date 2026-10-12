import { LightningElement } from 'lwc';
import getStats from '@salesforce/apex/CaptureDashboardController.getStats';
import getEvents from '@salesforce/apex/CaptureDashboardController.getEvents';

const CHANNEL_COLORS = { 'Self-scan': '#0176d3', Rep: '#fe9339', Kiosk: '#0b827c' };
const MATCHING_COLORS = {
    'Auto-matched': '#2e844a',
    'Reviewed by data steward': '#0176d3',
    'New HCP (auto-created)': '#8a63d2',
    'Waiting for review': '#fe9339',
    Discarded: '#a8a8a8',
    'Queued / error': '#c23934'
};
const CONSENT_COLORS = { Confirmed: '#2e844a', 'Pending confirmation': '#fe9339', Declined: '#ba0517' };
const R = 60;
const C = 2 * Math.PI * R;

/** Capture performance dashboard (mockup step 7) with event filter. */
export default class CaptureDashboard extends LightningElement {
    stats;
    events = [];
    eventId = '';
    error;

    connectedCallback() {
        this.init();
    }

    async init() {
        try {
            this.events = await getEvents();
        } catch (e) {
            this.error = this.msg(e);
        }
        this.refresh();
    }

    async refresh() {
        try {
            this.stats = await getStats({ eventId: this.eventId || null });
            this.error = undefined;
        } catch (e) {
            this.error = this.msg(e);
        }
    }

    changeEvent(evt) {
        this.eventId = evt.target.value;
        this.refresh();
    }

    get eventOptions() {
        return this.events.map((e) => ({ ...e, selected: e.value === this.eventId }));
    }

    value(list, label) {
        const b = (list || []).find((x) => x.label === label);
        return b ? b.value : 0;
    }

    pct(n) {
        return this.stats.total ? Math.round((n / this.stats.total) * 100) : 0;
    }

    get kpis() {
        const s = this.stats;
        const auto = this.value(s.matching, 'Auto-matched');
        const reviewed = this.value(s.matching, 'Reviewed by data steward');
        const confirmed = this.value(s.consent, 'Confirmed');
        const pending = this.value(s.consent, 'Pending confirmation');
        return [
            { label: 'Total captures', value: s.total, cls: 'kpi' },
            { label: 'Auto-matched', value: `${this.pct(auto)}%`, cls: 'kpi g' },
            { label: 'Manually reviewed', value: `${this.pct(reviewed)}%`, cls: 'kpi b' },
            { label: 'Consent confirmed', value: `${this.pct(confirmed)}%`, cls: 'kpi g' },
            { label: 'Consent pending', value: `${this.pct(pending)}%`, cls: 'kpi a' }
        ];
    }

    bars(list, colorOf) {
        const max = Math.max(1, ...(list || []).map((b) => b.value));
        return (list || []).map((b) => ({
            ...b,
            style: `width:${(b.value / max) * 100}%;background:${colorOf(b.label)}`
        }));
    }

    get channelBars() {
        return this.bars(this.stats.byChannel, (l) => CHANNEL_COLORS[l] || '#0176d3');
    }

    get repBars() {
        return this.bars(this.stats.byRep, () => '#0176d3');
    }

    donut(list, colors) {
        const total = (list || []).reduce((a, b) => a + b.value, 0);
        let acc = 0;
        return (list || []).map((b) => {
            const len = total ? (b.value / total) * C : 0;
            const seg = {
                label: b.label,
                value: b.value,
                pct: total ? Math.round((b.value / total) * 100) : 0,
                color: colors[b.label] || '#888',
                swatch: `background:${colors[b.label] || '#888'}`,
                dash: `${len} ${C - len}`,
                offset: `${-acc}`
            };
            acc += len;
            return seg;
        });
    }

    get matchingDonut() {
        return this.donut(this.stats.matching, MATCHING_COLORS);
    }

    get consentDonut() {
        return this.donut(this.stats.consent, CONSENT_COLORS);
    }

    msg(e) {
        return (e && e.body && e.body.message) || (e && e.message) || 'Unexpected error';
    }
}
