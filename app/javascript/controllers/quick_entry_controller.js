import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["track", "primary", "details", "toggle", "amount", "summary", "currency", "idempotencyKey"];
  static values = { currencies: Object };

  connect() {
    this.expanded = false;
    this.accumulator = null;
    this.operation = null;
    this.replaceAmount = false;
    this.updateSummary();
    this.showPanel(this.element.querySelector(".field_with_errors") !== null);
  }

  toggle() {
    this.showPanel(!this.expanded);
    if (this.expanded) {
      this.detailsTarget.querySelector("button")?.focus();
    } else {
      this.toggleTarget.focus();
    }
  }

  showPanel(expanded) {
    this.expanded = expanded;
    this.trackTarget.classList.toggle("-translate-x-full", expanded);
    this.primaryTarget.inert = expanded;
    this.detailsTarget.inert = !expanded;
    this.toggleTarget.setAttribute("aria-expanded", expanded.toString());
  }

  revealInvalidField(event) {
    if (this.detailsTarget.contains(event.target)) this.showPanel(true);
  }

  reset() {
    this.showPanel(false);
    this.idempotencyKeyTarget.value = crypto.randomUUID();
  }

  restore(event) {
    if (event.persisted) this.reset();
  }

  preventZoom(event) {
    if (event.type === "dblclick" || event.type === "gesturestart" || event.touches?.length > 1) {
      if (event.cancelable) event.preventDefault();
    }
  }

  preventScroll(event) {
    this.preventZoom(event);
    if (!event.target.closest("[data-quick-entry-scroll]") && event.cancelable) {
      event.preventDefault();
    }
  }

  updateSummary(event) {
    if (event?.target === this.amountTarget && !this.settingAmount) this.digits = null;
    const currency = this.currentCurrency();
    this.summaryTarget.textContent = `${this.amountTarget.value || "0"} ${currency}`;
    if (this.currencyTarget.tagName === "SPAN") this.currencyTarget.textContent = currency;
  }

  currentCurrency() {
    if (this.currencyTarget.tagName !== "SPAN") return this.currencyTarget.value;
    const source = this.element.querySelector('[data-transfer-form-target="fromAccount"]');
    return this.currenciesValue[source?.value] || this.currencyTarget.textContent;
  }

  keypad(event) {
    const key = event.currentTarget.dataset.key;
    const operators = ["add", "subtract", "multiply", "divide"];
    if (operators.includes(key) || key === "equals") {
      this.calculate();
      this.operation = key === "equals" ? null : key;
      this.accumulator = Number(this.amountTarget.value || "0");
      this.replaceAmount = true;
      return;
    }

    const current = this.replaceAmount ? "" : (this.digits ?? this.amountTarget.value);
    this.replaceAmount = false;
    if (key === "backspace") {
      this.setAmount(current.slice(0, -1));
    } else if (key === "decimal") {
      if (!current.includes(".")) this.setAmount(`${current || "0"}.`);
    } else {
      this.setAmount(`${current}${key}`.replace(/^0+(?=\d)/, ""));
    }
  }

  calculate() {
    if (!this.operation || this.accumulator === null || this.replaceAmount) return;
    const right = Number(this.amountTarget.value || "0");
    let result;
    switch (this.operation) {
      case "add": result = this.accumulator + right; break;
      case "subtract": result = this.accumulator - right; break;
      case "multiply": result = this.accumulator * right; break;
      case "divide": result = right === 0 ? Number.NaN : this.accumulator / right; break;
    }
    if (Number.isFinite(result) && result >= 0) {
      this.setAmount(String(Number(result.toFixed(8))));
    }
    this.operation = null;
  }

  setAmount(value) {
    this.digits = value;
    this.settingAmount = true;
    this.amountTarget.value = value.endsWith(".") ? value.slice(0, -1) : value;
    this.amountTarget.dispatchEvent(new Event("input", { bubbles: true }));
    this.settingAmount = false;
    this.updateSummary();
  }
}
