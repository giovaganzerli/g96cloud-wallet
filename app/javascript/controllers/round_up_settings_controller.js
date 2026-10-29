import { Controller } from "@hotwired/stimulus";

// Account edit dialog: the destination account and multiplier only make sense
// once "Spiccioli" is on, so they stay out of the way until then.
export default class extends Controller {
  static targets = ["toggle", "details"];

  connect() {
    this.toggle();
  }

  toggle() {
    if (!this.hasToggleTarget || !this.hasDetailsTarget) {
      return;
    }

    this.detailsTarget.classList.toggle("hidden", !this.toggleTarget.checked);
  }
}
