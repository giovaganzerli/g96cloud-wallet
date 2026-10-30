import { Controller } from "@hotwired/stimulus";
import { flush } from "services/offline_transaction_queue";

export default class extends Controller {
  connect() {
    this.sync = () => flush();
    window.addEventListener("online", this.sync);
    this.sync();
  }

  disconnect() {
    window.removeEventListener("online", this.sync);
  }
}
