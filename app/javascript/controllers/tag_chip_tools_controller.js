import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = [
    "searchDialog",
    "createDialog",
    "search",
    "option",
    "createName",
  ];
  static values = { createUrl: String };

  openSearch() {
    this.searchDialogTarget.showModal();
    this.searchTarget.focus();
  }
  openCreate() {
    this.createDialogTarget.showModal();
    this.createNameTarget.focus();
  }
  preventSubmit(event) {
    event.preventDefault();
  }

  filter() {
    const query = this.searchTarget.value.toLowerCase();
    this.optionTargets.forEach((option) => {
      option.hidden = !option.textContent.toLowerCase().includes(query);
    });
  }

  select(event) {
    const input = this.element.querySelector(
      `input[value="${CSS.escape(event.currentTarget.dataset.id)}"]`,
    );
    if (input) {
      input.checked = !input.checked;
      input.dispatchEvent(new Event("change", { bubbles: true }));
    }
    event.currentTarget.classList.toggle("bg-container-inset", input?.checked);
  }

  async create(event) {
    event.preventDefault();
    if (!this.createNameTarget.value.trim()) {
      this.createNameTarget.focus();
      return;
    }
    const response = await fetch(this.createUrlValue, {
      method: "POST",
      credentials: "same-origin",
      headers: {
        "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")
          ?.content,
        Accept: "application/json",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ tag: { name: this.createNameTarget.value } }),
    });
    if (response.ok) window.location.reload();
  }
}
