const DATABASE = "wallet-offline-transactions";
const STORE = "queue";

function database() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DATABASE, 1);
    request.onupgradeneeded = () => request.result.createObjectStore(STORE, { keyPath: "id" });
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

async function withStore(mode, callback) {
  const db = await database();
  return new Promise((resolve, reject) => {
    const transaction = db.transaction(STORE, mode);
    const request = callback(transaction.objectStore(STORE));
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  }).finally(() => db.close());
}

function changed() {
  document.dispatchEvent(new Event("offline-transaction-queue:changed"));
}

export async function list() {
  const records = await withStore("readonly", store => store.getAll());
  return records.sort((left, right) => left.createdAt - right.createdAt);
}

export async function save(record) {
  await withStore("readwrite", store => store.put(record));
  changed();
  return record;
}

export async function remove(id) {
  await withStore("readwrite", store => store.delete(id));
  changed();
}

export function serializeForm(form) {
  return Array.from(new FormData(form).entries()).map(([key, value]) => [key, value]);
}

export function queueRecord(form) {
  const params = serializeForm(form);
  return save({
    id: crypto.randomUUID(),
    url: form.action,
    method: form.method || "post",
    params,
    createdAt: Date.now(),
    status: "pending",
    error: null,
  });
}

function paramsWithCurrentCsrf(params) {
  const csrf = document.querySelector("meta[name='csrf-token']")?.content;
  if (!csrf) return params;
  return params.map(([key, value]) => key === "authenticity_token" ? [key, csrf] : [key, value]);
}

export async function flush() {
  if (!navigator.onLine) return;

  const records = await list();
  for (const record of records.filter(item => item.status === "pending")) {
    try {
      const response = await fetch(record.url, {
        method: record.method,
        credentials: "same-origin",
        headers: { "Accept": "text/vnd.turbo-stream.html, text/html" },
        body: new URLSearchParams(paramsWithCurrentCsrf(record.params)),
      });

      if (response.ok) {
        await remove(record.id);
      } else {
        record.status = "error";
        record.error = `Server response: ${response.status}`;
        await save(record);
      }
    } catch (_error) {
      // The browser may report online while a connection is unavailable. Keep
      // the record pending so the next online event or app launch retries it.
      return;
    }
  }
}
