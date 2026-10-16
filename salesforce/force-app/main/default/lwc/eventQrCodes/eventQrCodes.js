import { LightningElement, api } from 'lwc';
import qrcode from 'c/qrCodeLib';
import getQrInfo from '@salesforce/apex/EventQrController.getQrInfo';

const PNG_SIZE = 1200; // px, enough for an A3 poster at ~100 dpi or an A4 at 150 dpi
const QUIET_ZONE = 4; // modules of white border required by the QR standard

function makeQr(text) {
    const qr = qrcode(0, 'M');
    qr.addData(text);
    qr.make();
    return qr;
}

function toPng(qr, size) {
    const count = qr.getModuleCount();
    const total = count + QUIET_ZONE * 2;
    const cell = Math.floor(size / total);
    const px = cell * total;
    const canvas = document.createElement('canvas');
    canvas.width = px;
    canvas.height = px;
    const ctx = canvas.getContext('2d');
    ctx.fillStyle = '#ffffff';
    ctx.fillRect(0, 0, px, px);
    ctx.fillStyle = '#000000';
    for (let r = 0; r < count; r++) {
        for (let c = 0; c < count; c++) {
            if (qr.isDark(r, c)) {
                ctx.fillRect((c + QUIET_ZONE) * cell, (r + QUIET_ZONE) * cell, cell, cell);
            }
        }
    }
    return canvas.toDataURL('image/png');
}

function toSvg(qr) {
    const count = qr.getModuleCount();
    const total = count + QUIET_ZONE * 2;
    let path = '';
    for (let r = 0; r < count; r++) {
        for (let c = 0; c < count; c++) {
            if (qr.isDark(r, c)) {
                path += `M${c + QUIET_ZONE} ${r + QUIET_ZONE}h1v1h-1z`;
            }
        }
    }
    const svg =
        `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${total} ${total}" shape-rendering="crispEdges">` +
        `<rect width="${total}" height="${total}" fill="#fff"/><path d="${path}" fill="#000"/></svg>`;
    return 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg);
}

/** Event record page: booth QR (self-scan) and kiosk QR, downloadable for posters. */
export default class EventQrCodes extends LightningElement {
    @api recordId;
    info;
    codes = [];
    error;
    notice;

    connectedCallback() {
        this.load();
    }

    async load() {
        try {
            this.info = await getQrInfo({ eventId: this.recordId });
            this.codes = [];
            if (this.info.configured) {
                this.codes = [
                    { key: 'qr', title: 'Booth poster – self-scan', hint: 'HCPs scan it with their phone camera.', url: this.info.selfScanUrl },
                    { key: 'kiosk', title: 'Kiosk tablet', hint: 'Scan once with the tablet to open the kiosk page.', url: this.info.kioskUrl }
                ].map((c) => {
                    const qr = makeQr(c.url);
                    return { ...c, png: toPng(qr, PNG_SIZE), svg: toSvg(qr) };
                });
            }
        } catch (e) {
            this.error = (e && e.body && e.body.message) || 'Could not load the event URLs.';
        }
    }

    get notConfigured() {
        return !this.info.configured;
    }

    get notPublic() {
        return this.info.configured && !this.info.publicEnabled;
    }

    download(evt) {
        const c = this.codes.find((x) => x.key === evt.currentTarget.dataset.key);
        const format = evt.currentTarget.dataset.format;
        const a = document.createElement('a');
        a.href = format === 'svg' ? c.svg : c.png;
        a.download = `QR-${this.info.fileName}-${c.key}.${format}`;
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
    }

    async copy(evt) {
        const c = this.codes.find((x) => x.key === evt.currentTarget.dataset.key);
        try {
            await navigator.clipboard.writeText(c.url);
            this.notice = 'Link copied.';
        } catch (e) {
            this.notice = c.url;
        }
    }
}
