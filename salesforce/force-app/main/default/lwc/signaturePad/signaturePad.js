import { LightningElement, api } from 'lwc';

/**
 * Finger/mouse signature canvas. Fires "signed" on the first stroke and
 * "cleared" when cleared. getDataUrl() returns a PNG data URL.
 */
export default class SignaturePad extends LightningElement {
    drawing = false;
    hasInk = false;
    ctx;

    renderedCallback() {
        if (this.ctx) {
            return;
        }
        const canvas = this.canvas;
        if (canvas) {
            this.ctx = canvas.getContext('2d');
            this.ctx.lineWidth = 4;
            this.ctx.lineCap = 'round';
            this.ctx.strokeStyle = '#032d60';
        }
    }

    get canvas() {
        return this.template.querySelector('canvas');
    }

    point(evt) {
        const canvas = this.canvas;
        const r = canvas.getBoundingClientRect();
        return [((evt.clientX - r.left) * canvas.width) / r.width, ((evt.clientY - r.top) * canvas.height) / r.height];
    }

    handleDown(evt) {
        evt.preventDefault();
        this.drawing = true;
        try {
            this.canvas.setPointerCapture(evt.pointerId);
        } catch (e) {
            // pointer capture is optional
        }
        const [x, y] = this.point(evt);
        this.ctx.beginPath();
        this.ctx.moveTo(x, y);
    }

    handleMove(evt) {
        if (!this.drawing) {
            return;
        }
        evt.preventDefault();
        const [x, y] = this.point(evt);
        this.ctx.lineTo(x, y);
        this.ctx.stroke();
        if (!this.hasInk) {
            this.hasInk = true;
            this.dispatchEvent(new CustomEvent('signed'));
        }
    }

    handleUp() {
        this.drawing = false;
    }

    @api
    clear() {
        const canvas = this.canvas;
        if (canvas && this.ctx) {
            this.ctx.clearRect(0, 0, canvas.width, canvas.height);
        }
        if (this.hasInk) {
            this.hasInk = false;
            this.dispatchEvent(new CustomEvent('cleared'));
        }
    }

    @api
    isEmpty() {
        return !this.hasInk;
    }

    @api
    getDataUrl() {
        return this.hasInk ? this.canvas.toDataURL('image/png') : null;
    }
}
