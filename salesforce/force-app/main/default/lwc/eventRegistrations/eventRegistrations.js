import { LightningElement, api } from 'lwc';
import getSummary from '@salesforce/apex/EventRegistrationService.getSummary';

const REFRESH_MS = 15000;

/** Registered / checked in / not arrived / walk-ins of an event, read live from the attendees. */
export default class EventRegistrations extends LightningElement {
    @api recordId;
    summary;
    error;
    updatedAt;
    timer;

    connectedCallback() {
        this.refresh();
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.timer = setInterval(() => {
            if (document.visibilityState === 'visible') {
                this.refresh();
            }
        }, REFRESH_MS);
    }

    disconnectedCallback() {
        clearInterval(this.timer);
    }

    get refreshSeconds() {
        return REFRESH_MS / 1000;
    }

    async refresh() {
        try {
            this.summary = await getSummary({ eventId: this.recordId });
            this.error = undefined;
            this.updatedAt = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
        } catch (e) {
            this.error = (e && e.body && e.body.message) || 'Something went wrong.';
        }
    }
}
