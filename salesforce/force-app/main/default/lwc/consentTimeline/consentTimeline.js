import { LightningElement, api } from 'lwc';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import getTimeline from '@salesforce/apex/ConsentRecordController.getTimeline';
import simulateGigyaSync from '@salesforce/apex/ConsentRecordController.simulateGigyaSync';
import withdrawConsent from '@salesforce/apex/ConsentRecordController.withdrawConsent';

/** Consent record page: "Sent to Gigya" status and timeline (mockup step 6). */
export default class ConsentTimeline extends LightningElement {
    @api recordId;
    data;
    error;
    busy = false;

    connectedCallback() {
        this.load();
    }

    async load() {
        try {
            this.data = await getTimeline({ consentId: this.recordId });
            this.error = undefined;
        } catch (e) {
            this.error = this.msg(e);
        }
    }

    get steps() {
        return this.data.steps.map((s) => ({ ...s, icon: s.state === 'ok' ? '✓' : '…' }));
    }

    get bannerText() {
        if (this.data.sent) {
            return 'Sent to Gigya ✓';
        }
        if (this.data.gigyaStatus === 'Queued') {
            return 'Queued for Gigya';
        }
        if (this.data.gigyaStatus === 'Error') {
            return 'Gigya error – see timeline';
        }
        return 'Not sent yet – waiting for opt-in';
    }

    get bannerClass() {
        return this.data.sent ? 'gig' : 'gig w';
    }

    get captureUrl() {
        return this.data.captureId ? `/lightning/r/Capture__c/${this.data.captureId}/view` : null;
    }

    get taskLabel() {
        return this.data.taskSubject || '—';
    }

    simulate() {
        this.run(() => simulateGigyaSync({ consentId: this.recordId }));
    }

    withdraw() {
        // eslint-disable-next-line no-alert
        if (!window.confirm('Withdraw this consent? The HCP will be marked as opted out.')) {
            return;
        }
        this.run(() => withdrawConsent({ consentId: this.recordId }));
    }

    async run(action) {
        this.busy = true;
        try {
            await action();
            await this.load();
            await notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
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
