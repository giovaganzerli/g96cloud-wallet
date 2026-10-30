import { Controller } from "@hotwired/stimulus";
import { flush, list, queueRecord, remove, save, serializeForm } from "services/offline_transaction_queue";

export default class extends Controller {
  static targets = ["list", "empty", "count"];
  static values = { editLabel: String, deleteLabel: String, unnamedLabel: String };

  connect() {
    this.queueChanged = () => this.render();
    document.addEventListener("offline-transaction-queue:changed", this.queueChanged);
    this.render();
  }

  disconnect() {
    document.removeEventListener("offline-transaction-queue:changed", this.queueChanged);
  }

  async submit(event) {
    const form = event.currentTarget;
    if (this.editingId) {
      event.preventDefault();
      const record = (await list()).find(item => item.id === this.editingId);
      if (!record) return;
      record.params = serializeForm(form);
      record.status = "pending";
      record.error = null;
      await save(record);
      this.editingId = null;
      await flush();
      return;
    }

    if (navigator.onLine) return;
    event.preventDefault();
    if (!form.reportValidity()) return;
    await queueRecord(form);
    window.location.reload();
  }

  async edit(event) {
    const record = (await list()).find(item => item.id === event.currentTarget.dataset.id);
    if (!record) return;
    this.editingId = record.id;
    const values = new Map();
    record.params.forEach(([key, value]) => values.set(key, [ ...(values.get(key) || []), value ]));
    for (const [name, entries] of values) {
      const fields = this.element.closest("form")?.querySelectorAll(`[name="${CSS.escape(name)}"]`) || [];
      fields.forEach(field => {
        if (field.type === "checkbox") field.checked = entries.includes(field.value);
        else field.value = entries.at(-1);
        field.dispatchEvent(new Event("change", { bubbles: true }));
      });
    }
    this.element.closest("form")?.querySelector("[data-quick-entry-target='toggle']")?.click();
  }

  async delete(event) {
    await remove(event.currentTarget.dataset.id);
  }

  async render() {
    const records = await list();
    this.countTargets.forEach(target => { target.textContent = records.length; });
    this.emptyTarget.classList.toggle("hidden", records.length > 0);
    this.listTarget.replaceChildren(...records.map(record => this.row(record)));
  }

  row(record) {
    const params = Object.fromEntries(record.params);
    const item = document.createElement("div");
    item.className = "flex items-center justify-between gap-3 border-b border-tertiary py-3";
    const description = document.createElement("div");
    description.className = "min-w-0";
    const name = document.createElement("p");
    name.className = "truncate text-sm text-primary";
    name.textContent = params["entry[name]"] || params["transfer[name]"] || this.unnamedLabelValue;
    const status = document.createElement("p");
    status.className = "text-xs text-secondary";
    status.textContent = `${params["entry[amount]"] || params["transfer[amount]"] || ""}${record.error ? ` — ${record.error}` : ""}`;
    description.append(name, status);
    item.append(description);
    const actions = document.createElement("div");
    actions.className = "flex shrink-0 gap-2";
    [[this.editLabelValue, "edit"], [this.deleteLabelValue, "delete"]].forEach(([label, action]) => {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "text-sm text-secondary underline";
      button.textContent = label;
      button.dataset.id = record.id;
      button.dataset.action = `offline-transaction-queue#${action}`;
      actions.append(button);
    });
    item.append(actions);
    return item;
  }
}
