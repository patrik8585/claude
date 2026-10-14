import { LightningElement, api } from 'lwc';
import getSummary from '@salesforce/apex/EventRegistrationService.getSummary';
import importRegistrations from '@salesforce/apex/EventRegistrationService.importRegistrations';

/** CSV header (lower case, no spaces/underscores) -> Registrant field. English and Italian names. */
const HEADERS = {
    firstname: 'firstName',
    nome: 'firstName',
    lastname: 'lastName',
    surname: 'lastName',
    cognome: 'lastName',
    email: 'email',
    mail: 'email',
    specialty: 'specialty',
    speciality: 'specialty',
    specialita: 'specialty',
    city: 'city',
    citta: 'city',
    registrationnumber: 'registrationNumber',
    registration: 'registrationNumber',
    iscrizione: 'registrationNumber',
    organisation: 'organisation',
    organization: 'organisation',
    hospital: 'organisation',
    ospedale: 'organisation',
    consent: 'consent',
    consenso: 'consent',
    consentdate: 'consentDate',
    dataconsenso: 'consentDate',
    consentversion: 'consentVersion'
};
const YES = ['yes', 'y', 'true', '1', 'si', 'sì', 'x'];

function normHeader(h) {
    return (h || '')
        .toLowerCase()
        .normalize('NFD')
        .replace(/[̀-ͯ]/g, '')
        .replace(/[^a-z]/g, '');
}

/** Minimal CSV parser: quoted fields, doubled quotes, comma or semicolon separator. */
export function parseCsv(text) {
    const clean = (text || '').replace(/^﻿/, '');
    const firstLine = clean.split(/\r?\n/)[0] || '';
    const sep = (firstLine.match(/;/g) || []).length > (firstLine.match(/,/g) || []).length ? ';' : ',';
    const rows = [];
    let row = [];
    let field = '';
    let quoted = false;
    for (let i = 0; i < clean.length; i++) {
        const ch = clean[i];
        if (quoted) {
            if (ch === '"' && clean[i + 1] === '"') {
                field += '"';
                i++;
            } else if (ch === '"') {
                quoted = false;
            } else {
                field += ch;
            }
        } else if (ch === '"') {
            quoted = true;
        } else if (ch === sep) {
            row.push(field);
            field = '';
        } else if (ch === '\n' || ch === '\r') {
            if (ch === '\r' && clean[i + 1] === '\n') {
                i++;
            }
            row.push(field);
            rows.push(row);
            row = [];
            field = '';
        } else {
            field += ch;
        }
    }
    if (field !== '' || row.length) {
        row.push(field);
        rows.push(row);
    }
    return rows.filter((r) => r.some((c) => c.trim() !== ''));
}

export default class EventRegistrations extends LightningElement {
    @api recordId;
    summary;
    error;
    rows;
    fileName;
    importing = false;
    result;

    connectedCallback() {
        this.refresh();
    }

    async refresh() {
        this.error = undefined;
        try {
            this.summary = await getSummary({ eventId: this.recordId });
        } catch (e) {
            this.error = this.msg(e);
        }
    }

    handleFile(evt) {
        const file = evt.target.files && evt.target.files[0];
        this.result = undefined;
        this.rows = undefined;
        if (!file) {
            return;
        }
        this.fileName = file.name;
        const reader = new FileReader();
        reader.onload = () => {
            try {
                this.rows = this.toRegistrants(parseCsv(reader.result));
                if (!this.rows.length) {
                    this.rows = undefined;
                    this.error = 'No registrations found: check the header row (firstName, lastName, email, …).';
                } else {
                    this.error = undefined;
                }
            } catch (e) {
                this.error = 'The file could not be read as CSV.';
            }
        };
        reader.readAsText(file);
    }

    toRegistrants(table) {
        if (table.length < 2) {
            return [];
        }
        const fields = table[0].map((h) => HEADERS[normHeader(h)]);
        if (!fields.includes('lastName')) {
            return [];
        }
        return table.slice(1).map((cells) => {
            const r = {};
            fields.forEach((f, i) => {
                if (f) {
                    r[f] = (cells[i] || '').trim();
                }
            });
            r.consent = YES.includes((r.consent || '').toLowerCase());
            return r;
        });
    }

    get rowCount() {
        return this.rows ? this.rows.length : 0;
    }
    get consentCount() {
        return this.rows ? this.rows.filter((r) => r.consent).length : 0;
    }
    get previewRows() {
        return (this.rows || []).slice(0, 5).map((r, i) => ({
            key: `r${i}`,
            label: `${r.firstName || ''} ${r.lastName || ''} · ${r.email || 'no email'} · ${r.consent ? 'consent' : 'no consent'}`
        }));
    }
    get importLabel() {
        return this.importing ? 'Importing…' : `Import ${this.rowCount} registrations`;
    }
    get hasMessages() {
        return this.result && this.result.messages && this.result.messages.length > 0;
    }

    async runImport() {
        this.importing = true;
        this.error = undefined;
        try {
            this.result = await importRegistrations({ eventId: this.recordId, rows: this.rows });
            this.rows = undefined;
            const input = this.template.querySelector('input[type="file"]');
            if (input) {
                input.value = null;
            }
            await this.refresh();
        } catch (e) {
            this.error = this.msg(e);
        } finally {
            this.importing = false;
        }
    }

    msg(e) {
        return (e && e.body && e.body.message) || 'Something went wrong.';
    }
}
