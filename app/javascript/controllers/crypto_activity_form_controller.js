import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = [
    "kind",
    "symbol",
    "quantity",
    "occurredAt",
    "timeZone",
    "price",
    "value",
    "counterpart",
    "status",
    "suggestedPrice",
  ];
  static values = {
    quoteUrl: String,
    loading: String,
    unavailable: String,
    quoted: String,
  };

  connect() {
    this.autoPrice = this.suggestedPriceTarget.value === "true";
    this.autoValue = false;
    this.changeKind();
  }

  disconnect() {
    this.request?.abort();
  }

  changeKind() {
    this.counterpartTarget.hidden = this.kindTarget.value !== "swap";
  }

  marketChanged() {
    this.request?.abort();
    if (this.autoPrice) {
      this.priceTarget.value = "";
      this.autoPrice = false;
      this.suggestedPriceTarget.value = "false";
      if (this.autoValue) this.valueTarget.value = "";
    }
    this.lookup();
  }

  priceChanged() {
    this.autoPrice = false;
    this.suggestedPriceTarget.value = "false";
    this.calculateValue();
  }

  valueChanged() {
    this.autoValue = false;
    if (this.autoPrice) {
      this.priceTarget.value = "";
      this.autoPrice = false;
      this.suggestedPriceTarget.value = "false";
    }
  }

  quantityChanged() {
    this.calculateValue();
  }

  calculateValue() {
    if (this.valueTarget.value && !this.autoValue) return;
    const quantity = Number(this.quantityTarget.value);
    const price = Number(this.priceTarget.value);
    if (quantity > 0 && price > 0) {
      this.valueTarget.value = (quantity * price).toFixed(8);
      this.autoValue = true;
    } else if (this.autoValue) {
      this.valueTarget.value = "";
    }
  }

  async lookup() {
    if (this.priceTarget.value || this.valueTarget.value) return;
    if (!this.symbolTarget.value || !this.occurredAtTarget.value) return;
    this.request?.abort();
    const request = new AbortController();
    this.request = request;
    const url = new URL(this.quoteUrlValue, window.location.origin);
    url.searchParams.set("symbol", this.symbolTarget.value);
    url.searchParams.set("occurred_at", this.occurredAtTarget.value);
    url.searchParams.set("time_zone", this.timeZoneTarget.value);
    this.statusTarget.textContent = this.loadingValue;
    try {
      const response = await fetch(url, {
        headers: { Accept: "application/json" },
        signal: request.signal,
      });
      const data = await response.json();
      if (
        request.signal.aborted ||
        this.priceTarget.value ||
        this.valueTarget.value
      )
        return;
      if (!response.ok) throw new Error(data.error || this.unavailableValue);
      this.priceTarget.value = data.price;
      this.autoPrice = true;
      this.suggestedPriceTarget.value = "true";
      this.calculateValue();
      this.statusTarget.textContent = `${this.quotedValue} ${data.quoted_at}`;
    } catch (error) {
      if (error.name !== "AbortError") {
        this.statusTarget.textContent = error.message || this.unavailableValue;
      }
    }
  }
}
