import { Controller } from "@hotwired/stimulus";

// Fit text to its actual available width rather than guessing from digit count.
export default class extends Controller {
  static values = { maximum: { type: Number, default: 14 } };

  connect() {
    this.canvas = document.createElement("canvas");
    this.observer = new ResizeObserver(() => this.fit());
    this.observer.observe(this.element);
    this.mutations = new MutationObserver(() => this.fit());
    this.mutations.observe(this.element, { childList: true, characterData: true, subtree: true });
    this.fit();
    document.fonts.ready.then(() => {
      if (this.element.isConnected) this.fit();
    });
  }

  disconnect() {
    this.observer.disconnect();
    this.mutations.disconnect();
  }

  fit() {
    const style = getComputedStyle(this.element);
    const available = this.element.clientWidth - Number.parseFloat(style.paddingLeft) - Number.parseFloat(style.paddingRight) - 4;
    if (available <= 0) return;

    const context = this.canvas.getContext("2d");
    context.font = `${style.fontWeight} ${this.maximumValue}px ${style.fontFamily}`;
    const text = this.element.value || this.element.textContent.trim() || this.element.placeholder || "0";
    const width = context.measureText(text).width;
    const size = Math.min(this.maximumValue, this.maximumValue * available / Math.max(width, 1));
    this.element.style.fontSize = `${size}px`;
  }
}
