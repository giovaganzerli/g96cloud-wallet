const CACHE_VERSION = 'v2-wallet-8ad5b8fbb493';
const QUICK_ENTRY_CACHE = 'quick-entry-v1';
const OFFLINE_ASSETS = [
  '/offline.html',
  '/branding/wallet-8ad5b8fbb493-512.png'
];

// Install event - cache the offline page and assets
self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_VERSION).then((cache) => {
      return cache.addAll(OFFLINE_ASSETS);
    })
  );
  // Activate immediately
  self.skipWaiting();
});

// Activate event - clean up old caches
self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((cacheNames) => {
      return Promise.all(
        cacheNames.map((cacheName) => {
          if (cacheName !== CACHE_VERSION) {
            return caches.delete(cacheName);
          }
        })
      );
    }).then(() => {
      // Take control of all pages immediately
      return self.clients.claim();
    })
  );
});

// Fetch event - serve offline page when network fails
self.addEventListener('fetch', (event) => {
  // Handle navigation requests (page loads)
  if (event.request.mode === 'navigate') {
    event.respondWith(
      fetch(event.request).then((response) => {
        if (new URL(event.request.url).pathname === '/transactions/quick-new' && response.ok) {
          caches.open(QUICK_ENTRY_CACHE).then(cache => cache.put(event.request, response.clone()));
        }
        return response;
      }).catch((error) => {
        if (new URL(event.request.url).pathname === '/transactions/quick-new') {
          return caches.match(event.request).then(response => response || caches.match('/offline.html'));
        }
        // Only show offline page for network errors
        if (error.name === 'TypeError' || !navigator.onLine) {
          return caches.match('/offline.html');
        }
        throw error;
      })
    );
  }
  // Handle offline assets (logo, etc.)
  else if (OFFLINE_ASSETS.some(asset => new URL(event.request.url).pathname === asset)) {
    event.respondWith(
      caches.match(event.request).then((response) => {
        return response || fetch(event.request);
      })
    );
  }
  else if (["script", "style", "font", "image"].includes(event.request.destination) && new URL(event.request.url).origin === self.location.origin) {
    event.respondWith(
      fetch(event.request).then((response) => {
        if (response.ok) caches.open(QUICK_ENTRY_CACHE).then(cache => cache.put(event.request, response.clone()));
        return response;
      }).catch(() => caches.match(event.request))
    );
  }
});

// Add a service worker for processing Web Push notifications:
//
// self.addEventListener("push", async (event) => {
//   const { title, options } = await event.data.json()
//   event.waitUntil(self.registration.showNotification(title, options))
// })
//
// self.addEventListener("notificationclick", function(event) {
//   event.notification.close()
//   event.waitUntil(
//     clients.matchAll({ type: "window" }).then((clientList) => {
//       for (let i = 0; i < clientList.length; i++) {
//         let client = clientList[i]
//         let clientPath = (new URL(client.url)).pathname
//
//         if (clientPath == event.notification.data.path && "focus" in client) {
//           return client.focus()
//         }
//       }
//
//       if (clients.openWindow) {
//         return clients.openWindow(event.notification.data.path)
//       }
//     })
//   )
// })
