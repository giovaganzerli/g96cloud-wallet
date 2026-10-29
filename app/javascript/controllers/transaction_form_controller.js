import ExchangeRateFormController from "controllers/exchange_rate_form_controller";

// Connects to data-controller="transaction-form"
export default class extends ExchangeRateFormController {
  static targets = [
    ...ExchangeRateFormController.targets,
    "account",
    "currency",
    "idempotencyKey",
    "natureField",
    "cashbackSection",
    "cashbackToggle",
    "cashbackDetails",
    "cashbackValue",
    "cashbackType",
    "cashbackTypeFixed",
    "cashbackTypePercentage",
    "cashbackPreview",
    "roundUpSection",
    "roundUpToggle",
    "roundUpPreview",
  ];

  static values = {
    ...ExchangeRateFormController.values,
    roundUpAccounts: Object,
    roundUpPreviewTemplate: String,
  };

  connect() {
    super.connect?.();
    this.roundUpAccountId = this.hasAccountTarget ? this.accountTarget.value : null;
    this.updateCashbackAvailability();
    this.updateRoundUp();
  }

  onNatureChange(event) {
    const nature =
      event?.detail?.nature ||
      (this.hasNatureFieldTarget ? this.natureFieldTarget.value : "outflow");

    if (this.hasCashbackSectionTarget) {
      if (nature === "outflow") {
        this.cashbackSectionTarget.classList.remove("hidden");
        this.updateCashbackAvailability();
      } else {
        this.cashbackSectionTarget.classList.add("hidden");
        if (this.hasCashbackToggleTarget && this.cashbackToggleTarget.checked) {
          this.cashbackToggleTarget.checked = false;
          this.toggleCashback();
        }
      }
    }

    this.updateRoundUp();
  }

  onAccountChange() {
    this.checkCurrencyDifference();
    this.updateRoundUp(true);
  }

  onAmountChange() {
    super.onAmountChange();
    this.updateCashbackAvailability();
    this.updateRoundUpPreview();
  }

  updateCashbackAvailability() {
    if (!this.hasCashbackToggleTarget) {
      return;
    }

    const rawAmount = this.hasAmountTarget ? this.amountTarget.value : "";
    const amount = Number.parseFloat(rawAmount?.replace(",", "."));
    const hasValidAmount = !Number.isNaN(amount) && amount > 0;

    this.cashbackToggleTarget.disabled = !hasValidAmount;

    if (!hasValidAmount && this.cashbackToggleTarget.checked) {
      this.cashbackToggleTarget.checked = false;
      this.toggleCashback();
    } else if (hasValidAmount && this.cashbackToggleTarget.checked) {
      this.updateCashbackPreview();
    }
  }

  toggleCashback() {
    if (!this.hasCashbackToggleTarget || !this.hasCashbackDetailsTarget) {
      return;
    }

    const isEnabled = this.cashbackToggleTarget.checked;

    if (isEnabled) {
      this.cashbackDetailsTarget.classList.remove("hidden");
      if (this.hasCashbackValueTarget) {
        this.cashbackValueTarget.disabled = false;
        this.cashbackValueTarget.required = true;
        this.cashbackValueTarget.focus();
      }
      this.updateCashbackPreview();
    } else {
      this.cashbackDetailsTarget.classList.add("hidden");
      if (this.hasCashbackValueTarget) {
        this.cashbackValueTarget.disabled = true;
        this.cashbackValueTarget.required = false;
        this.cashbackValueTarget.value = "";
      }
      this.hideCashbackPreview();
    }
  }

  selectCashbackType(event) {
    event.preventDefault();
    const selectedType = event.currentTarget.dataset.type;

    if (this.hasCashbackTypeTarget) {
      this.cashbackTypeTarget.value = selectedType;
    }

    const isFixed = selectedType === "fixed";

    if (this.hasCashbackTypeFixedTarget) {
      this.cashbackTypeFixedTarget.classList.toggle(
        "segmented-control__segment--active",
        isFixed,
      );
      this.cashbackTypeFixedTarget.setAttribute(
        "aria-pressed",
        isFixed ? "true" : "false",
      );
    }

    if (this.hasCashbackTypePercentageTarget) {
      this.cashbackTypePercentageTarget.classList.toggle(
        "segmented-control__segment--active",
        !isFixed,
      );
      this.cashbackTypePercentageTarget.setAttribute(
        "aria-pressed",
        !isFixed ? "true" : "false",
      );
    }

    if (this.hasCashbackValueTarget) {
      if (selectedType === "percentage") {
        this.cashbackValueTarget.max = "100";
        this.cashbackValueTarget.placeholder = "0 %";
      } else {
        this.cashbackValueTarget.removeAttribute("max");
        this.cashbackValueTarget.placeholder = "0.00";
      }
    }

    this.updateCashbackPreview();
  }

  onCashbackValueChange() {
    this.updateCashbackPreview();
  }

  updateCashbackPreview() {
    if (!this.hasCashbackPreviewTarget) {
      return;
    }

    const type = this.hasCashbackTypeTarget
      ? this.cashbackTypeTarget.value
      : "fixed";
    if (type !== "percentage") {
      this.hideCashbackPreview();
      return;
    }

    const rawAmount = this.hasAmountTarget ? this.amountTarget.value : "";
    const amount = Number.parseFloat(rawAmount?.replace(",", "."));
    const rawVal = this.hasCashbackValueTarget
      ? this.cashbackValueTarget.value
      : "";
    const val = Number.parseFloat(rawVal?.replace(",", "."));

    if (!Number.isNaN(amount) && amount > 0 && !Number.isNaN(val) && val > 0) {
      const calculated = (amount * (val / 100)).toFixed(2);
      const currency = this.hasCurrencyTarget ? this.currencyTarget.value : "";
      this.cashbackPreviewTarget.textContent =
        `= ${calculated} ${currency}`.trim();
      this.cashbackPreviewTarget.classList.remove("hidden");
    } else {
      this.hideCashbackPreview();
    }
  }

  hideCashbackPreview() {
    if (this.hasCashbackPreviewTarget) {
      this.cashbackPreviewTarget.textContent = "";
      this.cashbackPreviewTarget.classList.add("hidden");
    }
  }

  // "Spiccioli" (spare change) only applies to expenses on an account whose
  // owner enabled it, so the row follows both the nature tabs and the
  // account select. Switching to an eligible account re-checks the toggle
  // (default on); a 422 re-render keeps whatever the user submitted.
  updateRoundUp(resetSelection = false) {
    if (!this.hasRoundUpSectionTarget) {
      return;
    }

    const nature = this.hasNatureFieldTarget
      ? this.natureFieldTarget.value
      : "outflow";
    const accountId = this.hasAccountTarget ? this.accountTarget.value : "";
    const config = this.hasRoundUpAccountsValue
      ? this.roundUpAccountsValue[accountId]
      : null;
    const eligible = nature === "outflow" && Boolean(config);
    const wasHidden = this.roundUpSectionTarget.classList.contains("hidden");

    this.roundUpSectionTarget.classList.toggle("hidden", !eligible);

    if (!eligible) {
      if (this.hasRoundUpToggleTarget) {
        this.roundUpToggleTarget.checked = false;
      }
      return;
    }

    if (
      wasHidden ||
      resetSelection ||
      this.roundUpAccountId !== accountId
    ) {
      this.roundUpAccountId = accountId;
      if (this.hasRoundUpToggleTarget) {
        this.roundUpToggleTarget.checked = true;
      }
    }

    this.updateRoundUpPreview();
  }

  toggleRoundUp() {
    this.updateRoundUpPreview();
  }

  updateRoundUpPreview() {
    if (!this.hasRoundUpPreviewTarget) {
      return;
    }

    const accountId = this.hasAccountTarget ? this.accountTarget.value : "";
    const config = this.hasRoundUpAccountsValue
      ? this.roundUpAccountsValue[accountId]
      : null;

    if (!config) {
      this.roundUpPreviewTarget.textContent = "";
      return;
    }

    const destination = config.destination;
    const multiplier = `x${config.multiplier}`;
    const rawAmount = this.hasAmountTarget ? this.amountTarget.value : "";
    const amount = Number.parseFloat(rawAmount?.replace(",", "."));

    if (Number.isNaN(amount) || amount <= 0) {
      this.roundUpPreviewTarget.textContent = `${destination} (${multiplier})`;
      return;
    }

    // Mirrors Transaction::RoundUpCreator: round up to the next whole unit,
    // and move one whole unit when the amount is already round.
    const whole = Math.ceil(amount);
    let difference = whole - amount;
    if (difference <= 0) {
      difference = 1;
    }
    const moved = (difference * config.multiplier).toFixed(2);
    const template =
      this.roundUpPreviewTemplateValue || "%{amount} → %{destination} (%{multiplier})";

    this.roundUpPreviewTarget.textContent = template
      .replace("%{amount}", moved)
      .replace("%{destination}", destination)
      .replace("%{multiplier}", multiplier);
  }

  // Two independent restoration paths can hand a user this exact page - and
  // its hidden idempotency field - back without a server round trip: Turbo's
  // own snapshot cache (back button within the app, wired via
  // turbo:before-cache) and the browser's native bfcache (back/forward
  // across a full navigation, or a duplicated tab, wired via a persisted
  // pageshow). Either one skips the "new" action's SecureRandom.uuid, so if
  // the original submission already committed, replaying that token on a
  // *different*, edited submission would silently redirect onto the stale
  // entry instead of creating the new one. Rotating on both events - rather
  // than only one - ensures any later restore starts from a fresh,
  // unconsumed token regardless of which cache served the page.
  refreshIdempotencyKey() {
    if (this.hasIdempotencyKeyTarget) {
      this.idempotencyKeyTarget.value = this.#generateUUID();
    }
  }

  refreshIdempotencyKeyIfPersisted(event) {
    if (event.persisted) {
      this.refreshIdempotencyKey();
    }
  }

  // crypto.randomUUID() only exists in secure contexts (HTTPS/localhost),
  // but self-hosted deployments of this app are commonly reverse-proxied or
  // reached over plain HTTP on a LAN, where it's undefined and would throw
  // from inside the cache-restore handlers above - leaving the stale,
  // already-consumed token in place. crypto.getRandomValues has no such
  // restriction, so build a v4 UUID manually when randomUUID is missing;
  // the server's UUID_FORMAT check requires this exact shape.
  #generateUUID() {
    if (crypto.randomUUID) {
      return crypto.randomUUID();
    }

    const bytes = crypto.getRandomValues(new Uint8Array(16));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const hex = [...bytes].map((byte) => byte.toString(16).padStart(2, "0"));

    return [
      hex.slice(0, 4).join(""),
      hex.slice(4, 6).join(""),
      hex.slice(6, 8).join(""),
      hex.slice(8, 10).join(""),
      hex.slice(10, 16).join(""),
    ].join("-");
  }

  hasRequiredExchangeRateTargets() {
    if (
      !this.hasAccountTarget ||
      !this.hasCurrencyTarget ||
      !this.hasDateTarget
    ) {
      return false;
    }

    return true;
  }

  getExchangeRateContext() {
    if (!this.hasRequiredExchangeRateTargets()) {
      return null;
    }

    const accountId = this.accountTarget.value;
    const currency = this.currencyTarget.value;
    const date = this.dateTarget.value;

    if (!accountId || !currency) {
      return null;
    }

    const accountCurrency = this.accountCurrenciesValue[accountId];
    if (!accountCurrency) {
      return null;
    }

    return {
      fromCurrency: currency,
      toCurrency: accountCurrency,
      date,
    };
  }

  isCurrentExchangeRateState(fromCurrency, toCurrency, date) {
    if (!this.hasRequiredExchangeRateTargets()) {
      return false;
    }

    const currentAccountId = this.accountTarget.value;
    const currentCurrency = this.currencyTarget.value;
    const currentDate = this.dateTarget.value;
    const currentAccountCurrency =
      this.accountCurrenciesValue[currentAccountId];

    return (
      fromCurrency === currentCurrency &&
      toCurrency === currentAccountCurrency &&
      date === currentDate
    );
  }

  onCurrencyChange() {
    this.checkCurrencyDifference();
    this.updateCashbackPreview();
  }
}
