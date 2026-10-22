import { LightningElement } from 'lwc';
import getHcoOptions from '@salesforce/apex/MatchingWorkbenchController.getHcoOptions';
import getReviewQueue from '@salesforce/apex/MatchingWorkbenchController.getReviewQueue';
import bulkResolve from '@salesforce/apex/CaptureReviewController.bulkResolve';

const BULK_TEXT = {
    recommended: 'match each selected capture to its recommended HCP',
    new: 'create a new HCP for each selected capture',
    discard: 'discard the selected captures'
};
const MAX_BULK = 50;

/**
 * Data steward workbench: review queue with bulk actions and the side-by-side review in a modal
 * (Previous / Next, moves on to the next capture after a decision), matching accuracy.
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

    noticeTimer;

    connectedCallback() {
        this.init();
    }

    disconnectedCallback() {
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
        }
    }

    tabClass(name) {
        return this.tab === name ? 'on' : '';
    }
    get queueTabClass() {
        return this.tabClass('queue');
    }
    get accuracyTabClass() {
        return this.tabClass('accuracy');
    }
    get isQueue() {
        return this.tab === 'queue';
    }
    get isAccuracy() {
        return this.tab === 'accuracy';
    }

    get hospitalOptions() {
        return this.hcoOptions
            .filter((o) => !o.parent)
            .map((o) => ({ ...o, queueSelected: o.value === this.queueHospital }));
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

    // ---------------------------------------------------------------- side-by-side review (modal)

    openCapture(evt) {
        evt.preventDefault();
        this.selectedCaptureId = evt.currentTarget.dataset.id;
        this.focusModal();
    }

    closeCapture() {
        this.selectedCaptureId = undefined;
    }

    focusModal() {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        requestAnimationFrame(() => {
            const modal = this.template.querySelector('.modal');
            if (modal) {
                modal.focus();
            }
        });
    }

    modalKey(evt) {
        if (evt.key === 'Escape') {
            this.closeCapture();
        }
    }

    get selectedIndex() {
        return this.queue.findIndex((r) => r.id === this.selectedCaptureId);
    }

    get modalTitle() {
        const i = this.selectedIndex;
        if (i < 0) {
            return 'Side-by-side review';
        }
        const r = this.queue[i];
        return `${r.name} · ${r.fullName} (${i + 1} of ${this.queue.length})`;
    }

    get noPrev() {
        return this.selectedIndex <= 0;
    }

    get noNext() {
        const i = this.selectedIndex;
        return i < 0 || i >= this.queue.length - 1;
    }

    prevCapture() {
        const i = this.selectedIndex;
        if (i > 0) {
            this.selectedCaptureId = this.queue[i - 1].id;
        }
    }

    nextCapture() {
        const i = this.selectedIndex;
        if (i >= 0 && i < this.queue.length - 1) {
            this.selectedCaptureId = this.queue[i + 1].id;
        }
    }

    /** After a decision the queue reloads and the modal moves on to the next capture (or closes at the end). */
    async handleResolved() {
        const i = this.selectedIndex;
        const resolvedId = this.selectedCaptureId;
        await this.loadQueue();
        if (this.queue.some((r) => r.id === resolvedId)) {
            return; // still to review (e.g. matching re-run): stay on it
        }
        const rest = this.queue;
        if (rest.length === 0) {
            this.selectedCaptureId = undefined;
            this.toast('Capture resolved. The review queue is empty.');
            return;
        }
        const next = rest[Math.min(Math.max(i, 0), rest.length - 1)];
        this.selectedCaptureId = next.id;
        this.toast('Capture resolved. Showing the next one.');
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
