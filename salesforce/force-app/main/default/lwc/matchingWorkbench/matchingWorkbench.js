import { LightningElement } from 'lwc';
import getHcoOptions from '@salesforce/apex/MatchingWorkbenchController.getHcoOptions';
import getReviewQueue from '@salesforce/apex/MatchingWorkbenchController.getReviewQueue';
import getPairs from '@salesforce/apex/MatchingWorkbenchController.getPairs';
import getPairDetail from '@salesforce/apex/MatchingWorkbenchController.getPairDetail';
import mergePair from '@salesforce/apex/MatchingWorkbenchController.mergePair';
import markNotDuplicate from '@salesforce/apex/MatchingWorkbenchController.markNotDuplicate';
import reopenPair from '@salesforce/apex/MatchingWorkbenchController.reopenPair';
import runDuplicateScan from '@salesforce/apex/MatchingWorkbenchController.runDuplicateScan';
import getJobStatus from '@salesforce/apex/MatchingWorkbenchController.getJobStatus';
import getMerges from '@salesforce/apex/MatchingWorkbenchController.getMerges';
import bulkResolve from '@salesforce/apex/CaptureReviewController.bulkResolve';

const BULK_TEXT = {
    recommended: 'match each selected capture to its recommended HCP',
    new: 'create a new HCP for each selected capture',
    discard: 'discard the selected captures'
};
const MAX_BULK = 50;

/**
 * Data steward workbench: review queue with bulk actions and side-by-side review,
 * duplicate HCP pairs with field-by-field merge, matching accuracy, merge history.
 */
export default class MatchingWorkbench extends LightningElement {
    tab = 'queue';
    error;
    notice;
    busy = false;
    hcoOptions = [];

    // queue
    queue = [];
    selected = {};
    queueHospital = '';
    confidence = '';
    selectedCaptureId;
    confirmBulk;

    // pairs
    pairs = [];
    pairStatus = 'Open';
    pairHospital = '';
    pairDepartment = '';
    minScore = 50;
    pair;
    masterSide = 'A';
    picks = {};
    note = '';
    confirmMerge = false;
    scanJobId;
    scanStatus;
    scanTimer;
    noticeTimer;

    // merges
    merges = [];

    connectedCallback() {
        this.init();
    }

    disconnectedCallback() {
        clearTimeout(this.scanTimer);
        clearTimeout(this.noticeTimer);
    }

    async init() {
        try {
            this.hcoOptions = await getHcoOptions();
        } catch (e) {
            this.error = this.msg(e);
            return;
        }
        this.loadQueue();
    }

    // ---------------------------------------------------------------- tabs

    selectTab(evt) {
        this.tab = evt.currentTarget.dataset.tab;
        this.error = undefined;
        if (this.tab === 'queue') {
            this.loadQueue();
        } else if (this.tab === 'pairs') {
            this.loadPairs();
        } else if (this.tab === 'merges') {
            this.loadMerges();
        }
    }

    tabClass(name) {
        return this.tab === name ? 'on' : '';
    }
    get queueTabClass() {
        return this.tabClass('queue');
    }
    get pairsTabClass() {
        return this.tabClass('pairs');
    }
    get accuracyTabClass() {
        return this.tabClass('accuracy');
    }
    get mergesTabClass() {
        return this.tabClass('merges');
    }
    get isQueue() {
        return this.tab === 'queue';
    }
    get isPairs() {
        return this.tab === 'pairs';
    }
    get isAccuracy() {
        return this.tab === 'accuracy';
    }
    get isMerges() {
        return this.tab === 'merges';
    }

    get hospitalOptions() {
        return this.hcoOptions
            .filter((o) => !o.parent)
            .map((o) => ({ ...o, queueSelected: o.value === this.queueHospital, pairSelected: o.value === this.pairHospital }));
    }

    get departmentOptions() {
        return this.hcoOptions.filter((o) => o.parent && o.parent === this.pairHospital).map((o) => ({ ...o, selected: o.value === this.pairDepartment }));
    }

    get noDepartments() {
        return !this.pairHospital;
    }

    // ---------------------------------------------------------------- review queue

    async loadQueue() {
        this.busy = true;
        try {
            this.queue = await getReviewQueue({ hospitalId: this.queueHospital || null, confidence: this.confidence || null });
            const ids = new Set(this.queue.map((r) => r.id));
            const kept = {};
            Object.keys(this.selected).forEach((k) => {
                if (ids.has(k) && this.selected[k]) {
                    kept[k] = true;
                }
            });
            this.selected = kept;
            this.error = undefined;
        } catch (e) {
            this.error = this.msg(e);
        } finally {
            this.busy = false;
        }
    }

    changeQueueHospital(evt) {
        this.queueHospital = evt.target.value;
        this.loadQueue();
    }

    changeConfidence(evt) {
        this.confidence = evt.target.value;
        this.loadQueue();
    }

    get queueRows() {
        return this.queue.map((r) => ({
            ...r,
            checked: !!this.selected[r.id],
            rowClass: r.id === this.selectedCaptureId ? 'sel' : '',
            scoreClass: this.scoreClass(r.topScore),
            confClass: r.confidence === 'High' ? 'pill ok' : r.confidence === 'Medium' ? 'pill warn' : 'pill grey'
        }));
    }

    get queueCount() {
        return this.queue.length;
    }

    get queueEmpty() {
        return !this.busy && this.queue.length === 0;
    }

    get selectedIds() {
        return Object.keys(this.selected).filter((k) => this.selected[k]);
    }

    get selectedCount() {
        return this.selectedIds.length;
    }

    get allSelected() {
        return this.queue.length > 0 && this.selectedIds.length === Math.min(this.queue.length, MAX_BULK);
    }

    get bulkDisabled() {
        return this.busy || this.selectedIds.length === 0;
    }

    toggleRow(evt) {
        const id = evt.target.dataset.id;
        const next = { ...this.selected, [id]: evt.target.checked };
        if (Object.keys(next).filter((k) => next[k]).length > MAX_BULK) {
            evt.target.checked = false;
            this.error = `Select at most ${MAX_BULK} captures at a time.`;
            return;
        }
        this.selected = next;
    }

    toggleAll(evt) {
        const next = {};
        if (evt.target.checked) {
            this.queue.slice(0, MAX_BULK).forEach((r) => {
                next[r.id] = true;
            });
        }
        this.selected = next;
    }

    bulk(evt) {
        this.confirmBulk = evt.currentTarget.dataset.action;
    }

    get confirmBulkText() {
        const n = this.selectedIds.length;
        return `You are about to ${BULK_TEXT[this.confirmBulk]} (${n} ${n === 1 ? 'capture' : 'captures'}). Consents and attendees are created as for a single review.`;
    }

    cancelBulk() {
        this.confirmBulk = undefined;
    }

    async runBulk() {
        const action = this.confirmBulk;
        this.busy = true;
        this.error = undefined;
        try {
            const r = await bulkResolve({ captureIds: this.selectedIds, action });
            this.toast(r.message);
            this.selected = {};
            this.confirmBulk = undefined;
            this.selectedCaptureId = undefined;
            await this.loadQueue();
        } catch (e) {
            this.error = this.msg(e);
        } finally {
            this.busy = false;
        }
    }

    openCapture(evt) {
        evt.preventDefault();
        this.selectedCaptureId = evt.currentTarget.dataset.id;
    }

    closeCapture() {
        this.selectedCaptureId = undefined;
    }

    handleResolved() {
        this.toast('Capture resolved');
        this.loadQueue();
    }

    // ---------------------------------------------------------------- pairs

    async loadPairs() {
        this.busy = true;
        try {
            this.pairs = await getPairs({
                status: this.pairStatus,
                hospitalId: this.pairHospital || null,
                departmentId: this.pairDepartment || null,
                minScore: Number(this.minScore) || 0
            });
            this.error = undefined;
        } catch (e) {
            this.error = this.msg(e);
        } finally {
            this.busy = false;
        }
    }

    changeStatus(evt) {
        this.pairStatus = evt.target.value;
        this.pair = undefined;
        this.loadPairs();
    }

    changePairHospital(evt) {
        this.pairHospital = evt.target.value;
        this.pairDepartment = '';
        this.loadPairs();
    }

    changePairDepartment(evt) {
        this.pairDepartment = evt.target.value;
        this.loadPairs();
    }

    changeMinScore(evt) {
        this.minScore = evt.target.value;
        this.loadPairs();
    }

    get pairRows() {
        return this.pairs.map((p) => ({
            ...p,
            rowClass: this.pair && this.pair.pair.id === p.id ? 'sel click' : 'click',
            scoreClass: this.scoreClass(p.score)
        }));
    }

    get pairsEmpty() {
        return !this.busy && this.pairs.length === 0;
    }

    async openPair(evt) {
        const id = evt.currentTarget.dataset.id;
        this.busy = true;
        this.confirmMerge = false;
        this.note = '';
        try {
            const d = await getPairDetail({ pairId: id });
            this.pair = d;
            this.masterSide = d.suggestedMaster === d.pair.contactB ? 'B' : 'A';
            this.resetPicks();
            this.error = undefined;
        } catch (e) {
            this.error = this.msg(e);
        } finally {
            this.busy = false;
        }
    }

    closePair() {
        this.pair = undefined;
    }

    /** Default value per field: the survivor's, or the other one when the survivor's is blank. */
    resetPicks() {
        const picks = {};
        const keep = this.masterSide;
        const other = keep === 'A' ? 'B' : 'A';
        this.pair.fields.forEach((f) => {
            const keepValue = keep === 'A' ? f.valueA : f.valueB;
            picks[f.field] = keepValue ? keep : other;
        });
        this.picks = picks;
    }

    get readOnlyPair() {
        return !this.canDecide;
    }

    get canDecide() {
        return this.pair && this.pair.pair.status === 'Open';
    }

    get canReopen() {
        return this.pair && this.pair.pair.status === 'Not a duplicate';
    }

    get masterIsA() {
        return this.masterSide === 'A';
    }
    get masterIsB() {
        return this.masterSide === 'B';
    }
    get masterAClass() {
        return this.masterSide === 'A' ? 'keep' : '';
    }
    get masterBClass() {
        return this.masterSide === 'B' ? 'keep' : '';
    }
    get urlA() {
        return this.pair ? `/lightning/r/Contact/${this.pair.pair.contactA}/view` : null;
    }
    get urlB() {
        return this.pair ? `/lightning/r/Contact/${this.pair.pair.contactB}/view` : null;
    }
    get keepName() {
        return this.masterSide === 'A' ? this.pair.pair.nameA : this.pair.pair.nameB;
    }
    get dropName() {
        return this.masterSide === 'A' ? this.pair.pair.nameB : this.pair.pair.nameA;
    }
    get suggestedName() {
        if (!this.pair) {
            return '';
        }
        return this.pair.suggestedMaster === this.pair.pair.contactB ? this.pair.pair.nameB : this.pair.pair.nameA;
    }

    pickMaster(evt) {
        this.masterSide = evt.target.value;
        this.confirmMerge = false;
        this.resetPicks();
    }

    pickValue(evt) {
        this.picks = { ...this.picks, [evt.target.dataset.field]: evt.target.value };
    }

    get fieldRows() {
        if (!this.pair) {
            return [];
        }
        return this.pair.fields.map((f) => {
            const pick = this.picks[f.field];
            return {
                ...f,
                valueA: f.valueA || '—',
                valueB: f.valueB || '—',
                pickA: pick === 'A',
                pickB: pick === 'B',
                locked: f.same || !this.canDecide,
                rowClass: f.same ? 'same' : 'diff',
                clsA: pick === 'A' ? 'chosen' : '',
                clsB: pick === 'B' ? 'chosen' : ''
            };
        });
    }

    changeNote(evt) {
        this.note = evt.target.value;
    }

    askMerge() {
        this.confirmMerge = true;
    }

    cancelMerge() {
        this.confirmMerge = false;
    }

    async doMerge() {
        const p = this.pair.pair;
        const masterId = this.masterSide === 'A' ? p.contactA : p.contactB;
        const choices = {};
        Object.keys(this.picks).forEach((field) => {
            choices[field] = this.picks[field] === this.masterSide ? 'master' : 'duplicate';
        });
        this.busy = true;
        this.error = undefined;
        try {
            await mergePair({ pairId: p.id, masterId, choices });
            this.toast(`Merged: ${this.dropName} → ${this.keepName}. Recorded in Merge history.`);
            this.pair = undefined;
            this.confirmMerge = false;
            await this.loadPairs();
        } catch (e) {
            this.error = this.msg(e);
        } finally {
            this.busy = false;
        }
    }

    async notDuplicate() {
        this.busy = true;
        this.error = undefined;
        try {
            await markNotDuplicate({ pairId: this.pair.pair.id, note: this.note });
            this.toast('Marked as not a duplicate: this pair will not be proposed again.');
            this.pair = undefined;
            await this.loadPairs();
        } catch (e) {
            this.error = this.msg(e);
        } finally {
            this.busy = false;
        }
    }

    async reopen() {
        this.busy = true;
        try {
            await reopenPair({ pairId: this.pair.pair.id });
            this.toast('Pair re-opened.');
            this.pair = undefined;
            await this.loadPairs();
        } catch (e) {
            this.error = this.msg(e);
        } finally {
            this.busy = false;
        }
    }

    async runScan() {
        this.busy = true;
        try {
            this.scanJobId = await runDuplicateScan();
            this.scanStatus = 'Queued';
            this.pollScan();
        } catch (e) {
            this.error = this.msg(e);
        } finally {
            this.busy = false;
        }
    }

    pollScan() {
        clearTimeout(this.scanTimer);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.scanTimer = setTimeout(async () => {
            try {
                this.scanStatus = await getJobStatus({ jobId: this.scanJobId });
            } catch (e) {
                this.scanStatus = undefined;
                return;
            }
            if (this.scanStatus && /^(Completed|Failed|Aborted)/.test(this.scanStatus)) {
                this.loadPairs();
            } else {
                this.pollScan();
            }
        }, 4000);
    }

    // ---------------------------------------------------------------- merges

    async loadMerges() {
        this.busy = true;
        try {
            const rows = await getMerges();
            this.merges = rows.map((m) => ({ ...m, url: `/lightning/r/HCP_Merge__c/${m.id}/view` }));
        } catch (e) {
            this.error = this.msg(e);
        } finally {
            this.busy = false;
        }
    }

    get mergeRows() {
        return this.merges;
    }

    get mergesEmpty() {
        return !this.busy && this.merges.length === 0;
    }

    // ---------------------------------------------------------------- utils

    scoreClass(score) {
        if (score >= 70) {
            return 'score hi';
        }
        return score >= 50 ? 'score mid' : 'score lo';
    }

    toast(text) {
        this.notice = text;
        clearTimeout(this.noticeTimer);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.noticeTimer = setTimeout(() => {
            this.notice = undefined;
        }, 4000);
    }

    msg(e) {
        return (e && e.body && e.body.message) || (e && e.message) || 'Unexpected error';
    }
}
