import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  closed() {
    this.element.selectSheetOwner?.close();
  }
}
