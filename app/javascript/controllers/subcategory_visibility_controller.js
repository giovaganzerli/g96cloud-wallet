import { Controller } from "@hotwired/stimulus";

// Coordinates the outflows list and donut when category detail is enabled.
export default class extends Controller {
  static targets = ["subcategory", "count", "donut"];
  static values = { categories: Array, show: { type: Boolean, default: false } };

  connect() {
    this.#render();
  }

  toggle() {
    this.showValue = !this.showValue;
    this.#render();
  }

  #render() {
    this.subcategoryTargets.forEach((subcategory) => {
      subcategory.hidden = !this.showValue;
    });

    if (this.hasCountTarget) {
      const count = this.showValue
        ? this.categoriesValue.reduce(
            (total, category) => total + 1 + category.subcategories.length,
            0,
          )
        : this.categoriesValue.length;
      this.countTarget.textContent = count;
    }

    if (this.hasDonutTarget) {
      const segments = this.showValue
        ? this.categoriesValue.flatMap((category) => [
            ...(category.direct_amount > 0
              ? [{ ...category, amount: category.direct_amount }]
              : []),
            ...category.subcategories,
          ])
        : this.categoriesValue;
      this.donutTarget.dataset.donutChartSegmentsValue = JSON.stringify(segments);
    }
  }
}
